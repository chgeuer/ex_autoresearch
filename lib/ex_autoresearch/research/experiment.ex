defmodule ExAutoresearch.Research.Experiment do
  @moduledoc """
  A single experiment — one version of the model, trained and evaluated.

  Stores everything: the Elixir source code, the config, training results,
  which LLM model proposed it, and whether it was kept or discarded.
  This is the lab notebook entry.
  """

  use Ash.Resource,
    domain: ExAutoresearch.Research,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "experiments"
    repo ExAutoresearch.Repo
  end

  actions do
    defaults [:read]

    create :record do
      primary? true
      accept [
        :run_id,
        :version_id,
        :status,
        :code,
        :description,
        :reasoning,
        :parent_id,
        :model,
        :config,
        :final_loss,
        :training_seconds,
        :num_steps,
        :kept,
        :error
      ]
    end

    update :complete do
      accept [:status, :final_loss, :training_seconds, :num_steps, :kept, :error]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :run_id, :uuid_v7, allow_nil?: false
    attribute :version_id, :string, allow_nil?: false
    attribute :status, :atom,
      constraints: [one_of: [:pending, :running, :completed, :crashed, :discarded]],
      default: :pending
    attribute :code, :string, allow_nil?: true
    attribute :description, :string
    attribute :reasoning, :string
    attribute :parent_id, :uuid_v7
    attribute :model, :string
    attribute :config, :map
    attribute :final_loss, :float
    attribute :training_seconds, :float
    attribute :num_steps, :integer
    attribute :kept, :boolean, default: false
    attribute :error, :string

    timestamps()
  end

  relationships do
    belongs_to :run, ExAutoresearch.Research.Run
  end
end
