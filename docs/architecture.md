# ex_autoresearch Architecture

## Overview

An Elixir port of Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) — an autonomous AI research framework that lets LLM agents conduct hyperparameter tuning and architectural experimentation on a GPT language model overnight.

## System Architecture

```mermaid
graph TB
    subgraph "Phoenix LiveView (UI)"
        LV[DashboardLive<br/>Real-time experiment monitoring]
    end

    subgraph "Agent Layer (Jido + GH Copilot)"
        RA[Researcher Agent<br/>Jido.Agent]
        GHC[GitHub Copilot LLM<br/>jido_ghcopilot]
        RA --> GHC
    end

    subgraph "Training Layer (Nx/Axon/EXLA)"
        TR[Trainer GenServer]
        GPT[GPT Model<br/>Axon + defn]
        OPT[Optimizer<br/>Polaris AdamW → Muon]
        DL[DataLoader<br/>Best-fit packing]
        TR --> GPT
        TR --> OPT
        TR --> DL
    end

    subgraph "Cluster Layer (Distributed Erlang)"
        CL[Cluster GenServer<br/>Capability registry]
        LW[LocalWorker<br/>CUDA 5070]
        SSH[SSHBackend<br/>Remote nodes]
        CL --> LW
        CL --> SSH
    end

    subgraph "Persistence (Ash + SQLite)"
        EXP[Experiment Resource]
        CFG[Config Resource]
        RES[Result Resource]
    end

    LV -->|PubSub| TR
    LV -->|PubSub| RA
    RA -->|:rpc.call| CL
    CL -->|route| TR
    TR -->|save| EXP
    RA -->|read/write| CFG
    TR -->|save| RES

    style LV fill:#818cf8,color:#fff
    style RA fill:#f472b6,color:#fff
    style GPT fill:#34d399,color:#fff
    style CL fill:#fbbf24,color:#000
```

## Distributed GPU Cluster

```mermaid
graph LR
    subgraph "Framework Laptop 16"
        ML[Main BEAM<br/>Phoenix + Agent]
        ROCm1[ROCm iGPU<br/>96GB shared]
        CUDA1[LocalWorker BEAM<br/>CUDA 5070]
        ML --> ROCm1
        ML -.->|spawn| CUDA1
    end

    subgraph "Framework Desktop"
        SSH1[SSH Worker BEAM<br/>ROCm iGPU<br/>128GB shared]
    end

    subgraph "ThreadRipper"
        SSH2[SSH Worker BEAM<br/>CUDA 4090<br/>24GB VRAM]
    end

    ML -.->|SSH + rsync| SSH1
    ML -.->|SSH + rsync| SSH2

    style ML fill:#818cf8,color:#fff
    style ROCm1 fill:#ef4444,color:#fff
    style CUDA1 fill:#22c55e,color:#fff
    style SSH1 fill:#ef4444,color:#fff
    style SSH2 fill:#22c55e,color:#fff
```

## Experiment Loop

```mermaid
sequenceDiagram
    participant Agent as Researcher Agent
    participant LLM as GitHub Copilot
    participant Cluster as Cluster
    participant Trainer as Trainer
    participant DB as SQLite

    Agent->>DB: Load previous results
    Agent->>LLM: "Analyze results, propose experiment"
    LLM-->>Agent: Config changes (depth, lr, batch_size...)

    Agent->>Cluster: best_node_for(:train)
    Cluster-->>Agent: node@host

    Agent->>Trainer: start_training(config, node)
    Note over Trainer: 5-minute time budget

    loop Training Loop
        Trainer->>Trainer: Forward + backward pass
        Trainer-->>Agent: PubSub: progress update
    end

    Trainer->>Trainer: Evaluate BPB
    Trainer-->>Agent: PubSub: training complete

    Agent->>DB: Save experiment result
    Agent->>LLM: "BPB improved? Keep or discard?"
    LLM-->>Agent: Decision + reasoning

    alt Improvement
        Agent->>DB: Mark as kept
    else Regression
        Agent->>DB: Mark as discarded
    end

    Agent->>Agent: Next experiment...
```

## GPT Model Architecture (Axon)

```mermaid
graph TD
    IN[Token IDs<br/>batch × seq_len] --> EMB[Token Embedding<br/>Axon.embedding]
    EMB --> B1[Transformer Block 1]
    B1 --> B2[Transformer Block 2]
    B2 --> BN[Transformer Block N]
    BN --> NORM[RMS Norm]
    NORM --> HEAD[LM Head<br/>Linear → Softcap]
    HEAD --> OUT[Logits<br/>batch × seq_len × vocab]

    subgraph "Transformer Block"
        RN1[RMS Norm] --> ATT[Causal Self-Attention<br/>+ RoPE + Window]
        ATT --> RS1[Residual + λ scaling]
        RS1 --> RN2[RMS Norm]
        RN2 --> MLP1[MLP<br/>ReLU²]
        MLP1 --> RS2[Residual + λ scaling]
    end

    style IN fill:#94a3b8,color:#fff
    style EMB fill:#818cf8,color:#fff
    style HEAD fill:#f472b6,color:#fff
    style OUT fill:#94a3b8,color:#fff
```

## Key Dependencies

| Layer | Package | Purpose |
|-------|---------|---------|
| **GPU Backend** | `xla_rocm` (path dep) | EXLA with CUDA 12.8 + ROCm 7.2 support |
| **Tensors** | `nx ~> 0.10` | Numerical computing |
| **Compiler** | `exla ~> 0.10` | XLA JIT compilation to GPU |
| **Model** | `axon` | Neural network definition |
| **Optimizer** | `polaris` | AdamW (+ custom Muon later) |
| **Agent** | `jido` + `jido_ghcopilot` | LLM agent loop via GitHub Copilot |
| **Persistence** | `ash` + `ash_sqlite` | Experiment tracking |
| **UI** | Phoenix LiveView | Real-time dashboard |
| **Jobs** | Oban (Lite/SQLite) | Ancillary tasks only (data downloads, cleanup) |
| **Cluster** | Distributed Erlang | Multi-node GPU coordination |

## Directory Structure

```
lib/
├── ex_autoresearch/
│   ├── application.ex              # OTP supervision tree
│   ├── repo.ex                     # SQLite repo
│   │
│   ├── model/                      # GPT model (Axon/Nx)
│   │   ├── gpt.ex                  # Full GPT model assembly
│   │   ├── attention.ex            # Causal self-attention + RoPE
│   │   ├── mlp.ex                  # MLP block (ReLU²)
│   │   └── config.ex               # GPTConfig struct
│   │
│   ├── training/                   # Training loop
│   │   ├── trainer.ex              # GenServer: time-budgeted training
│   │   ├── optimizer.ex            # AdamW / Muon setup
│   │   ├── scheduler.ex            # LR warmup/warmdown
│   │   └── metrics.ex              # BPB evaluation
│   │
│   ├── data/                       # Data pipeline
│   │   ├── tokenizer.ex            # BPE tokenizer wrapper
│   │   ├── loader.ex               # Best-fit packing dataloader
│   │   └── downloader.ex           # HuggingFace parquet download
│   │
│   ├── research/                   # Ash domain: experiment tracking
│   │   ├── research.ex             # Ash domain
│   │   ├── experiment.ex           # Ash resource: experiment runs
│   │   └── config_snapshot.ex      # Ash resource: hyperparameter snapshots
│   │
│   ├── agent/                      # LLM agent loop
│   │   ├── researcher.ex           # Jido.Agent: experiment orchestrator
│   │   ├── tools.ex                # Agent tools (train, evaluate, git)
│   │   └── program.ex              # System prompt from program.md
│   │
│   └── cluster/                    # Multi-GPU coordination
│       ├── cluster.ex              # Capability registry GenServer
│       ├── local_worker.ex         # Same-machine second BEAM
│       ├── ssh_backend.ex          # Remote BEAM via SSH
│       └── network.ex              # IP detection
│
├── ex_autoresearch_web/
│   ├── live/
│   │   └── dashboard_live.ex       # Main experiment dashboard
│   ├── router.ex
│   └── ...
│
├── config/
│   ├── config.exs                  # EXLA backend, Oban queues
│   └── runtime.exs                 # GPU_TARGET switching
│
└── docs/
    ├── architecture.md             # This file
    ├── training.md                 # GPT training details
    ├── agent.md                    # Agent loop design
    └── cluster.md                  # Distributed GPU setup
```
