# Referee: Early Stopping and GPU Migration

The Referee monitors concurrent training trials across multiple GPUs
and makes real-time decisions about which experiments to keep, kill,
or migrate to faster hardware.

## Problem

When running two experiments in parallel on GPUs of different speeds
(e.g., AMD ROCm iGPU + NVIDIA CUDA discrete), naive comparison fails:

```
ROCm trial:  84,906 steps  → loss 0.001184
CUDA trial: 193,709 steps  → loss 0.000506  ← always "wins"
```

The CUDA GPU runs ~2× more steps in the same time, so it always has
lower loss — but that doesn't mean its architecture is better. The
ROCm trial might have a superior architecture that would win at equal
step counts.

**Solution**: Use step-based budgets for fair comparison, and a referee
to kill losing trials early and migrate winners to faster hardware.

## Architecture

```
┌───────────────────────────────────────────────────────┐
│ Researcher (experiment_loop)                          │
│                                                       │
│  ┌──────────────┐          ┌──────────────┐           │
│  │ gpu_loop     │          │ gpu_loop     │           │
│  │ (ROCm)       │          │ (CUDA)       │           │
│  │              │          │              │           │
│  │ LLM → train  │          │ LLM → train  │           │
│  └──────┬───────┘          └──────┬───────┘           │
│         │ PubSub :step events     │                   │
│         └────────────┬────────────┘                   │
│                      ▼                                │
│              ┌────────────────┐                       │
│              │   Referee      │                       │
│              │                │                       │
│              │ Compares loss  │                       │
│              │ at checkpoint  │                       │
│              │                │                       │
│              │ Actions:       │                       │
│              │ • Kill loser   │──→ Runner.halt(vid)   │
│              │ • Migrate      │──→ checkpoint + queue │
│              │   winner       │                       │
│              └────────────────┘                       │
└───────────────────────────────────────────────────────┘
```

## How It Works

### Step 1: Monitoring

The Referee subscribes to PubSub `"agent:events"` and tracks step
events from all in-flight trials. Each event contains:

```elixir
{:step, %{version_id: "abc123", step: 50000, loss: 0.00234, progress: 33.3}}
```

It maintains a sliding window of the last 100 `{step, loss}` points
per trial.

### Step 2: Comparison at Checkpoint

At 50% of `step_budget` (e.g., step 75,000 of a 150k budget), the
referee compares all in-flight trials. It finds each trial's loss at
the closest recorded point to the checkpoint step.

A trial is killed if either condition is met:

| Condition | Threshold | Rationale |
|-----------|-----------|-----------|
| Loss ratio | >20% worse than best | Architecture is clearly inferior |
| Loss trending up | >5% rise over last 10 points | Unstable training (bad learning rate, divergence) |

### Step 3: Kill Decision

```
Trial A (ROCm):  loss 0.0015 at step 75k  ← winner
Trial B (CUDA):  loss 0.0020 at step 75k  ← 33% worse, killed
```

The referee sends `Runner.halt(version_id)` to both the local node
and all connected remote nodes via `:rpc.cast`. The Runner checks an
ETS flag every 500 iterations and stops the training loop.

### Step 4: GPU Migration (Optional)

If the **winner is on the slower GPU**, the referee triggers migration:

```
1. Kill loser (CUDA)      → frees the fast GPU
2. Halt winner (ROCm)     → saves checkpoint
3. Wait 2s                → checkpoint serialization
4. Queue migration        → {version_id, code, checkpoint_binary}
5. CUDA gpu_loop picks up → Runner.resume on fast GPU
```

## Checkpoint Serialization

When a trial is halted by the referee, the Runner serializes the full
Axon training state:

```elixir
# What gets serialized:
checkpoint = Axon.Loop.serialize_state(final_state, [:compressed])

# Contains:
# - Model parameters (all layer weights and biases)
# - Optimizer state (Adam momentum vectors, step counts)
# - Current epoch and iteration counters
# - Accumulated metrics
```

The checkpoint is stored in an ETS table (`Runner.Checkpoints`) and
retrieved by the migration system.

### Cross-Node Transfer

Checkpoints are portable across GPU backends because:

1. `Nx.serialize/2` produces backend-agnostic tensor binaries
2. `Axon.Loop.deserialize_state/2` reconstructs on the target backend
3. The EXLA JIT recompiles for the target GPU automatically

```elixir
# On ROCm node: serialize
binary = Axon.Loop.serialize_state(state, [:compressed])

# Transfer to CUDA node via :rpc.call
# On CUDA node: deserialize and resume
prev_state = Axon.Loop.deserialize_state(binary)
loop = Axon.Loop.trainer(model, loss_fn, opt)
       |> Axon.Loop.from_state(prev_state)
Axon.Loop.run(loop, data, %{}, iterations: remaining_steps)
```

## Runner Integration

### Halt Signal

The Runner uses an ETS table (`Runner.HaltSignals`) for cross-process
halt signaling. The training loop's `halt_handler` checks every 500
iterations:

```elixir
halt? =
  cond do
    step_budget && steps >= step_budget -> true    # normal completion
    elapsed >= time_budget_ms -> true               # safety timeout
    rem(steps, 500) == 0 and halted?(version_id) -> true  # referee kill
    true -> false
  end
```

### Resume

`Runner.resume/3` deserializes a checkpoint and continues training:

```elixir
Runner.resume(module, checkpoint_binary,
  version_id: "abc123",
  step_budget: 150_000,
  time_budget: 86_400
)
```

The step counter offsets by `completed_steps` from the checkpoint, so
progress reporting and the step_budget halt condition use the correct
global step count.

## Researcher Integration

Each `gpu_loop` checks the migration queue before proposing a new
experiment:

```elixir
case check_migration_queue(target_node) do
  {:migrate, %{version_id: vid, code: code, checkpoint: binary}} ->
    # Compile code on target GPU, resume training from checkpoint
    resume_migrated_trial(run, label, target_node, migration)

  :none ->
    # Normal flow: ask LLM for proposal, train from scratch
    propose_and_run(run, label, target_node, llm_pid)
end
```

## Example Timeline

```
Time  ROCm GPU              CUDA GPU              Referee
────  ─────────────────     ─────────────────     ──────────────────
0:00  LLM → proposal A      LLM → proposal B
0:15  Training A (slow)      Training B (fast)
0:30  A: step 25k, loss 8    B: step 50k, loss 12
1:00  A: step 50k, loss 4    B: step 75k, loss 5   Compare at 75k:
                                                     B is 25% worse
1:01  A halted (checkpoint)  B killed               Kill B, migrate A
1:03                         Resume A from ckpt     Migration queued
1:05  LLM → proposal C      A continues (fast!)    
1:20  Training C             A: step 150k, done ✅  A kept as new best
1:30  C: step 25k            LLM → proposal D       
```

## Configuration

The referee is automatically started when:
- `step_budget` is set (step-based mode)
- Multiple GPU nodes are available

No configuration needed — it uses sensible defaults:
- Checkpoint at 50% of step_budget
- Kill threshold: 20% worse loss
- Trending-up detection: 5% rise over 10 sample points

## Limitations

- **Single comparison point**: Currently only compares at the 50%
  checkpoint. A multi-checkpoint approach (25%, 50%, 75%) would catch
  issues earlier.
- **Two trials only**: The current implementation assumes exactly 2
  concurrent trials. With 3+ GPUs, pairwise comparison would be needed.
- **No learning rate awareness**: The referee doesn't know about
  learning rate schedules — a trial might look bad during warmup but
  improve later. The 50% checkpoint avoids most warmup issues.
- **Checkpoint size**: Large models produce large checkpoints (~10-100MB
  compressed). Transfer over distributed Erlang is fast on localhost
  but could be slow over a network.
