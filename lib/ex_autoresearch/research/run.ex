defmodule ExAutoresearch.Research.Run do
  @moduledoc """
  A research run — a named session of autonomous experimentation.

  Each run has a tag (like "mar14-gpt"), a status, and a sequence of experiments.
  Runs can be stopped and resumed. The agent picks up where it left off
  by loading the run's experiment history from SQLite.
  """

  use Ash.Resource,
    domain: ExAutoresearch.Research,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "runs"
    repo ExAutoresearch.Repo
  end

  actions do
    defaults [:read]

    create :start do
      accept [:tag, :model, :time_budget, :base_config]
      primary? true
    end

    update :update_status do
      accept [:status, :model, :best_experiment_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tag, :string, allow_nil?: false
    attribute :status, :atom,
      constraints: [one_of: [:running, :paused, :completed]],
      default: :running
    attribute :model, :string, default: "claude-sonnet-4"
    attribute :time_budget, :integer, default: 15
    attribute :base_config, :map
    attribute :best_experiment_id, :uuid_v7

    timestamps()
  end

  relationships do
    has_many :experiments, ExAutoresearch.Research.Experiment
  end

  identities do
    identity :unique_tag, [:tag]
  end
end
