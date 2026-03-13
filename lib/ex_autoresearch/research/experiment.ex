defmodule ExAutoresearch.Research.Experiment do
  use Ash.Resource,
    domain: ExAutoresearch.Research,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "experiments"
    repo ExAutoresearch.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :record do
      accept [
        :experiment_id,
        :status,
        :config,
        :final_loss,
        :training_seconds,
        :num_steps,
        :n_layer,
        :n_embd,
        :description,
        :kept,
        :reasoning
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :experiment_id, :string, allow_nil?: false
    attribute :status, :atom, constraints: [one_of: [:completed, :crashed, :running]], default: :running
    attribute :config, :map
    attribute :final_loss, :float
    attribute :training_seconds, :float
    attribute :num_steps, :integer
    attribute :n_layer, :integer
    attribute :n_embd, :integer
    attribute :description, :string
    attribute :kept, :boolean, default: false
    attribute :reasoning, :string

    timestamps()
  end
end
