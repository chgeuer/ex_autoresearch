## Constraints

- **OUTPUT FORMAT: Print the complete defmodule as a fenced elixir code block in your response. Do NOT use any tools to create or write files. Just output the code as text.**
- Your module MUST be named `ExAutoresearch.Experiments.V_<version_id>` (the system fills in the version_id)
- Your module MUST implement these callbacks:
  - `config/0` — returns a map with model hyperparameters
  - `build/0` — returns an Axon model that takes `"input_ids"` {batch, seq_len} and outputs {batch, seq_len, vocab_size}
  - `optimizer/0` — returns a Polaris optimizer tuple
- Optional callbacks:
  - `loss_fn/2` — custom loss function (default: categorical_cross_entropy)
- Available libraries: Axon, Nx, Nx.Defn, Polaris, EXLA
- The model will be trained on next-token prediction with synthetic data
- Training runs for a fixed time budget (default 15 seconds, excluding JIT warmup)
