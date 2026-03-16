# ExAutoresearch

An autonomous ML research framework in Elixir that lets an LLM agent design, train, and iterate on GPT model architectures — hands-free, overnight, across multiple GPUs.

Inspired by Andrej Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) (Python), rebuilt from scratch on the BEAM to exploit Erlang/OTP's strengths: fault-tolerant concurrency, distributed multi-node GPU training, hot code reloading, and real-time LiveView dashboards.

![](docs/sample_screenshot.png)

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    DASHBOARD (LiveView)                     │
│   Campaign picker · LLM backend switch · Live loss curves   │
└────────────────────────┬────────────────────────────────────┘
                         │ PubSub
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              RESEARCHER (GenServer Agent Loop)              │
│  1. Load trial history from Ash/SQLite                      │
│  2. Prompt LLM: "Propose next experiment"                   │
│  3. Parse JSON response → generate Elixir module            │
│  4. Hot-load module into BEAM (no restart)                  │
│  5. Route training to best available GPU node               │
│  6. Train within fixed time/step budget                     │
│  7. Save trial to DB, repeat forever                        │
└────┬───────────────────────────────────────────────────┬────┘
     │                                                   │
     ▼                                                   ▼
┌──────────────────────────┐         ┌────────────────────────┐
│   RUNNER (per GPU node)  │         │   REFEREE (GenServer)  │
│  · Build Axon model      │ PubSub  │  · Monitor all trials  │
│  · Time-budgeted train   ├─────────┤  · Compare loss curves │
│  · Report step metrics   │         │  · Kill losers early   │
│  · Checkpoint on halt    │         │  · Migrate winners     │
└──────────────────────────┘         └────────────────────────┘
```

The agent loop follows the scientific method: make **one change at a time**, keep improvements, discard regressions, and learn from crashes. Failed experiments are fed back to the LLM with error context, and recurring crash patterns are auto-distilled into a `pitfalls.md` file that becomes part of the system prompt.

## Key Features

- **Pluggable LLM backends** — GitHub Copilot (via [jido_ghcopilot](https://github.com/chgeuer/jido_ghcopilot)), Claude (via `claude_agent_sdk`), or Gemini. Switch at runtime from the dashboard.
- **Multi-GPU orchestration** — Distribute experiments across ROCm and CUDA nodes simultaneously. The cluster module tracks node capabilities and routes work to the best available GPU.
- **Referee system** — Monitors concurrent trials and early-stops losing experiments to free GPUs. Can migrate a winning trial's checkpoint from a slow GPU to a faster one mid-training.
- **Hot code reloading** — Each experiment is a self-contained Elixir module compiled and loaded at runtime. No application restarts needed.
- **Ash/SQLite persistence** — Campaigns (named research sessions) and trials (individual experiments) are fully persisted with configs, source code, loss histories, and GPU metadata.
- **Adaptive budgeting** — Time-based (seconds) or step-based training budgets, configurable per campaign.
- **LiveView dashboard** — Real-time loss curves (ECharts), trial browser, code viewer, campaign management, and LLM backend selector.
- **Crash learning** — Compile and training errors are sent back to the LLM for self-correction. Recurring pitfalls are auto-distilled into the system prompt.

## Genesis

This project started on March 13, 2026 with a question: *"Can we port Karpathy's autoresearch from Python to Elixir?"* The answer turned out to be not just "yes" but "yes, and we can do things Python can't." The full conversations that bootstrapped this project are preserved in [`real_conversations/`](real_conversations/).

The key insight: Erlang/OTP gives you distributed computing, fault tolerance, and hot code reloading for free — exactly what an autonomous research agent needs. Instead of git-committing experiment files like the Python version, we hot-load versioned Elixir modules directly into the running BEAM, persist everything in SQLite via Ash, and use PubSub to coordinate multi-GPU training with live dashboard updates.

## Prerequisites

- **Elixir** ≥ 1.15 with OTP
- **GPU**: AMD (ROCm) or NVIDIA (CUDA 12+)
- **C/C++ compiler**: `clang` / `clang++` (used for NIF compilation)
- **LLM access**: At least one of:
  - GitHub Copilot (via `gh copilot` CLI)
  - Anthropic API key (for Claude)
  - Google API key (for Gemini)

## Quick Start

```bash
# Clone and setup
git clone https://github.com/chgeuer/ex_autoresearch.git
cd ex_autoresearch
mix setup

# Set GPU target (default: rocm)
export XLA_TARGET=rocm    # or: cuda12

# Start the app
just start                 # background, logs to run.log
just start-fg              # foreground, for debugging

# Open dashboard
just open                  # → http://localhost:4000
```

From the dashboard: pick an LLM backend, name your campaign, set a training budget, and hit **Start Research**. The agent will begin proposing and training experiments autonomously.

## Commands (`justfile`)

| Command | Description |
|---------|-------------|
| `just start` | Start app in background (main node + CUDA worker) |
| `just stop` | Stop all nodes |
| `just start-fg` | Start in foreground with visible output |
| `just status` | Check if the BEAM node is running |
| `just compile` | Compile default (ROCm) build |
| `just compile-cuda` | One-time CUDA build (downloads CUDA XLA archive) |
| `just open` | Open dashboard in browser (auto-starts if needed) |
| `just winner` | Print best experiment across all campaigns |
| `just gpu` | Show GPU utilization (nvidia-smi / rocm-smi) |
| `just rpc "EXPR"` | Execute an Elixir expression on the running node |

## Project Structure

```
lib/
├── ex_autoresearch/
│   ├── agent/               # LLM integration & agent loop
│   │   ├── researcher.ex    #   Main experiment loop (GenServer)
│   │   ├── referee.ex       #   Early-stopping monitor for multi-GPU
│   │   ├── program.ex       #   System prompt for LLM
│   │   ├── prompts.ex       #   Prompt composition & pitfall distillation
│   │   └── llm/             #   Pluggable backends (copilot, claude, gemini)
│   ├── research/            # Ash resources (domain model)
│   │   ├── campaign.ex      #   Named research session
│   │   └── trial.ex         #   Individual experiment record
│   ├── experiments/         # Experiment execution
│   │   ├── loader.ex        #   Hot-loads experiment modules into BEAM
│   │   ├── registry.ex      #   Trial history & best-trial tracking
│   │   └── runner.ex        #   Executes experiment, handles halt signals
│   ├── model/               # GPT model architecture (Axon)
│   │   ├── gpt.ex           #   Transformer model builder
│   │   ├── config.ex        #   Hyperparameter struct
│   │   └── attention.ex     #   Attention mechanism
│   ├── training/            # Training loop
│   │   ├── trainer.ex       #   Time/step-budgeted training
│   │   └── scheduler.ex     #   Learning rate schedules
│   ├── data/                # Dataset loading & tokenization
│   │   ├── loader.ex        #   Infinite batch stream
│   │   └── tokenizer.ex     #   Byte-pair encoding
│   └── cluster/             # Multi-node GPU orchestration
│       └── cluster.ex       #   Node registration & task routing
└── ex_autoresearch_web/
    └── live/
        └── dashboard_live.ex  # LiveView dashboard
```

## Multi-GPU Setup

The app supports running across multiple machines with different GPUs:

```bash
# On the main node (e.g., AMD ROCm laptop)
just start

# On a CUDA worker node (e.g., desktop with NVIDIA GPU)
just compile-cuda
XLA_TARGET=cuda GPU_TARGET=cuda elixir --sname cuda_worker --cookie devcookie -S mix run --no-halt
```

Nodes auto-discover each other via Erlang distribution. The cluster module tracks GPU capabilities per node and the researcher routes experiments to the best available hardware. The referee system monitors concurrent trials across GPUs and can migrate winning checkpoints between nodes.

## Example Output

After running overnight, `just winner` produces something like:

```
🏆 Best Experiment: v_najvrm8

| Metric         | Value                    |
|----------------|--------------------------|
| Loss           | 1.55e-4                  |
| Steps          | 50,000                   |
| Training time  | 37.5s                    |
| Campaign       | mar15-debug2             |
| Model          | claude-sonnet-4          |
```

Each trial includes the full Elixir source code, model config, reasoning, and an architecture diagram — all persisted in SQLite and browsable from the dashboard.

## Development

```bash
# Run precommit checks (compile warnings, format, tests)
mix precommit

# After changing Ash resources (Campaign, Trial):
mix ash.codegen <description> --yes
mix ash_sqlite.migrate

# Interactive shell
iex -S mix phx.server
```

## Tech Stack

| Layer | Technology |
|-------|------------|
| Language | Elixir 1.15+ / OTP |
| Web | Phoenix 1.8, LiveView 1.1, Bandit |
| ML | Nx, EXLA (ROCm/CUDA), Axon |
| Persistence | Ash Framework, AshSqlite, SQLite |
| Job queue | Oban |
| LLM clients | jido_ghcopilot, claude_agent_sdk, gemini_cli_sdk |
| Frontend | Tailwind CSS v4, ECharts, esbuild |

## Acknowledgments

- [Andrej Karpathy](https://github.com/karpathy) for the [autoresearch](https://github.com/karpathy/autoresearch) concept
- [Jido](https://github.com/agentjido) ecosystem for the GitHub Copilot integration
- The Elixir [Nx](https://github.com/elixir-nx) team for making ML on the BEAM possible
