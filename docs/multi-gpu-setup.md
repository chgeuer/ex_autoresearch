# Multi-GPU Training: Running ROCm + CUDA in Parallel

This guide explains how `ex_autoresearch` runs autonomous ML experiments on
multiple GPUs simultaneously — specifically, an AMD ROCm iGPU and an NVIDIA
CUDA discrete GPU on the same machine. Each GPU runs its own independent
experiment loop, sharing results through SQLite.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  Main BEAM node (ex_autoresearch@framework)     │
│  GPU_TARGET=rocm   XLA_TARGET=rocm              │
│                                                 │
│  ┌────────────┐  ┌───────────┐  ┌─────────────┐ │
│  │ Researcher │  │ Registry  │  │  SQLite DB  │ │
│  │ GenServer  │  │ (Ash/ETS) │  │  (shared)   │ │
│  └─────┬──────┘  └───────────┘  └─────────────┘ │
│        │                                        │
│  ┌─────┴──────────────────┐                     │
│  │  experiment_loop/1     │                     │
│  │                        │                     │
│  │  ┌──────────────────┐  │                     │
│  │  │ gpu_loop (ROCm)  │──┼── LLM → compile →   │
│  │  │ local/rocm       │  │   train locally     │
│  │  └──────────────────┘  │                     │
│  │  ┌──────────────────┐  │                     │
│  │  │ gpu_loop (CUDA)  │──┼── LLM → compile →   │
│  │  │ cuda_worker/cuda │  │   :rpc.call train   │
│  │  └──────────────────┘  │        │            │
│  └────────────────────────┘        │            │
│                                    │            │
│  ┌─────────────────────────────────┘            │
│  │ Node.connect / :rpc.call                     │
└──┼──────────────────────────────────────────────┘
   │
┌──┴──────────────────────────────────────────────┐
│  CUDA worker BEAM (cuda_worker@framework)       │
│  GPU_TARGET=cuda   XLA_TARGET=cuda12            │
│  LD_LIBRARY_PATH=_build/cuda_libs               │
│  WORKER_ONLY=1 (no Phoenix, no web server)      │
│                                                 │
│  Receives :rpc.call → Code.compile_string →     │
│  Runner.run (trains on NVIDIA GPU)              │
└─────────────────────────────────────────────────┘
```

## Why Two Separate BEAM Nodes?

EXLA links the XLA native library (`libxla_extension.so`) at NIF load time.
The ROCm and CUDA versions are ~730 MB each and link against incompatible
system libraries. A single BEAM process can only load ONE variant. The
solution: two BEAM processes on the same machine, connected via distributed
Erlang.

## Prerequisites

### 1. Compile the CUDA Build Variant

The main app compiles with `XLA_TARGET=rocm` by default. You need a second
build for CUDA:

```bash
XLA_TARGET=cuda GPU_TARGET=cuda MIX_BUILD_PATH=_build/cuda mix compile
```

This downloads the `cuda12` precompiled XLA archive and compiles the app
into `_build/cuda/` (separate from the default `_build/dev/`).

**Important**: The `mix.exs` maps `"cuda"` → `"cuda12"` for the XLA archive
name. If you set `XLA_TARGET=cuda12` directly, that also works.

### 2. Hermetic CUDA 12.8 Runtime Libraries

If your system has CUDA 13 (e.g. RTX 5070 Blackwell), the precompiled XLA
archive needs CUDA 12 libraries. The CUDA 13 compatibility symlinks don't
satisfy versioned symbol requirements (e.g. `libcudart.so.12` exists but
has CUDA 13 internal version symbols).

**Solution**: Use hermetic CUDA 12.8 libraries extracted from the XLA Docker
build cache:

```bash
mkdir -p _build/cuda_libs

# Option A: Copy from a basileus project that already has them
cp /path/to/basileus/_build/cuda_libs/*.so* _build/cuda_libs/

# Option B: Extract from Docker (see basileus docs/plans/scaling-gpu.md)
docker run --rm \
  -v xla-cuda-cache:/cache:ro \
  -v "$PWD/_build/cuda_libs":/output \
  ubuntu:24.04 bash -c '
    BAZEL="/cache/bazel/_bazel_root/*/external"
    for dir in cuda_cudart cuda_cublas cuda_cufft cuda_cusolver \
               cuda_cusparse cuda_nvcc cuda_cupti cuda_nvjitlink cuda_nvrtc; do
      LIB=$(find $BAZEL -path "*/$dir/lib" -type d 2>/dev/null | head -1)
      [ -d "$LIB" ] && cp -L "$LIB"/*.so* /output/ 2>/dev/null
    done
  '
```

Verify all dependencies resolve:

```bash
LD_LIBRARY_PATH=_build/cuda_libs ldd _build/cuda/lib/exla/priv/libexla.so | grep "not found"
# Should produce no output
```

### 3. Start the Main Node with Distribution

```bash
# The justfile 'start' command does this automatically:
elixir --sname ex_autoresearch --cookie devcookie -S mix phx.server
```

Or use the dev script:

```bash
scripts/dev_node.sh start
```

## How It Works

### Spawning the CUDA Worker

The `LocalWorker` module spawns a child BEAM process:

```elixir
# What LocalWorker does internally:
Port.open({:spawn_executable, "elixir"}, [
  args: ["--sname", "cuda_worker@framework", "--cookie", "devcookie",
         "-S", "mix", "run", "--no-halt"],
  env: [
    {"WORKER_ONLY", "1"},           # Skip Phoenix
    {"GPU_TARGET", "cuda"},         # EXLA client selection
    {"XLA_TARGET", "cuda12"},       # NIF variant
    {"MIX_BUILD_PATH", "_build/cuda"},
    {"LD_LIBRARY_PATH", "_build/cuda_libs"}
  ]
])
```

Key environment variables:

| Variable | Purpose |
|----------|---------|
| `WORKER_ONLY=1` | Skips Phoenix web server, runs training infra only |
| `GPU_TARGET=cuda` | Tells `config/runtime.exs` to use the CUDA EXLA client |
| `XLA_TARGET=cuda12` | Ensures the correct NIF is loaded |
| `MIX_BUILD_PATH=_build/cuda` | Uses the CUDA-compiled build |
| `LD_LIBRARY_PATH=_build/cuda_libs` | Hermetic CUDA 12.8 runtime libs |

After boot, `LocalWorker` calls `Node.connect(:cuda_worker@framework)` in a
retry loop. Once connected, the node auto-registers with the Cluster module.

### sname Resolution Bug (Fixed)

The original `LocalWorker` used `{"--sname", name}` where `name` was just
`"cuda_worker"`. But `Node.connect(:cuda_worker)` fails — distributed
Erlang needs the full `name@host` form even for snames. Fix: always include
the hostname:

```elixir
# Before (broken):
{"--sname", name}  # "cuda_worker"

# After (fixed):
host_part = node() |> Atom.to_string() |> String.split("@") |> List.last()
{"--sname", "#{name}@#{host_part}"}  # "cuda_worker@framework"
```

### Parallel Experiment Loops

The `Researcher` detects GPU nodes at campaign start:

```elixir
defp gpu_nodes do
  local = {"local/rocm", node()}
  workers = Node.list()
    |> Enum.filter(&(Atom.to_string(&1) =~ "worker" or Atom.to_string(&1) =~ "cuda"))
    |> Enum.map(fn n ->
      gpu = :rpc.call(n, System, :get_env, ["GPU_TARGET"], 5_000) || "unknown"
      {"#{n}/#{gpu}", n}
    end)
  [local | workers]
end
```

Then spawns one `Task` per GPU:

```elixir
tasks = Enum.map(nodes, fn {label, target_node} ->
  Task.async(fn -> gpu_loop(run, label, target_node) end)
end)
Task.await_many(tasks, :infinity)
```

Each `gpu_loop` is fully independent:

1. **Read shared state**: `Registry.best_trial(run.id)` from SQLite
2. **Call LLM**: Get a new experiment proposal (each loop calls independently)
3. **Compile locally**: `Loader.load(version_id, code)` on main node
4. **Train on target GPU**: Local → `Runner.run(module, ...)`, Remote → `:rpc.call`
5. **Write results**: `Registry.complete_trial(...)` back to SQLite
6. **Update best**: If improvement, `Registry.update_campaign_best(run, id)`
7. **Loop**: Go to step 1

### Remote Training via :rpc.call

For remote nodes, the source code is shipped and compiled there:

```elixir
defp run_on_node(target_node, _module, code, version_id, time_budget) do
  # Compile the experiment code on the remote node
  case :rpc.call(target_node, Code, :compile_string, [code], 30_000) do
    modules when is_list(modules) ->
      {remote_module, _bytecode} = List.last(modules)
      # Train on the remote node's GPU
      :rpc.call(target_node, Runner, :run,
        [remote_module, [version_id: version_id, time_budget: time_budget]],
        :infinity)
    {:badrpc, reason} ->
      %{status: :crashed, loss: nil, error: inspect(reason), ...}
  end
end
```

Why `:rpc.call` and not sending the compiled module? Because the module
references EXLA-compiled Nx tensors that are bound to the local node's GPU
context. The remote node needs to JIT-compile for its own GPU.

### Shared State: SQLite as Scoreboard

Both loops read `Registry.best_trial(run.id)` fresh before each iteration.
SQLite serializes writes automatically. Race conditions are benign:

- **Both improve simultaneously**: Both trials get `kept: true`, the one
  with lower loss becomes `best_trial_id`. Next iteration, both loops
  see the true global best.
- **Loop A improves while B is training**: B finishes, compares against
  the (now stale) baseline. If B also improved, it's kept. If not, it's
  discarded. Either way, B's next iteration picks up A's improvement.

## Starting a Campaign with Multiple GPUs

### Dynamically (on a running app)

```elixir
# 1. Start the Cluster GenServer (if not in supervision tree)
Supervisor.start_child(ExAutoresearch.Supervisor, ExAutoresearch.Cluster)

# 2. Spawn CUDA worker
Supervisor.start_child(ExAutoresearch.Supervisor,
  {ExAutoresearch.Cluster.LocalWorker, [
    name: "cuda_worker",
    gpu_target: "cuda",
    build_path: "_build/cuda"
  ]})

# 3. Wait for connection (check with Node.list())
# 4. Start research — Researcher auto-detects GPU nodes
Researcher.start_research(tag: "multi-gpu-test", time_budget: 15, max_time_budget: 300)
```

### Via the Supervision Tree

Add to `application.ex` children list:

```elixir
children = [
  # ... existing children ...
  ExAutoresearch.Cluster,
  {ExAutoresearch.Cluster.LocalWorker, [
    name: "cuda_worker", gpu_target: "cuda", build_path: "_build/cuda"
  ]},
  # ...
]
```

## Troubleshooting

### EXLA NIF won't load on CUDA worker

```
** (UndefinedFunctionError) function EXLA.NIF.start_log_sink/1 is undefined
```

Usually means `LD_LIBRARY_PATH` doesn't include the hermetic CUDA libs.
Verify:

```bash
LD_LIBRARY_PATH=_build/cuda_libs ldd _build/cuda/lib/exla/priv/libexla.so | grep "not found"
```

### Node.connect fails

Check that both nodes use the same cookie and naming scheme (both `--sname`
or both `--name`). Verify with `epmd -names`.

### "Name seems to be in use"

A stale BEAM process from a previous run. Find and kill it:

```bash
ps aux | grep cuda_worker | grep -v grep
kill -9 <PID>
```
