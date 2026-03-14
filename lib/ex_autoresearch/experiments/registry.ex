defmodule ExAutoresearch.Experiments.Registry do
  @moduledoc """
  Experiment registry backed by Ash/SQLite.

  All state is persisted — stops and resumes are seamless.
  Also maintains an ETS cache of loaded modules for fast access
  (modules can't be stored in SQLite, they're recompiled on resume).
  """

  use GenServer

  require Logger
  require Ash.Query

  alias ExAutoresearch.Research.{Campaign, Trial}
  alias ExAutoresearch.Experiments.Loader

  @modules_table __MODULE__.Modules

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Campaign management ---

  def start_campaign(tag, opts \\ []) do
    model = Keyword.get(opts, :model, "claude-sonnet-4")
    time_budget = Keyword.get(opts, :time_budget, 15)
    base_config = Keyword.get(opts, :base_config, %{})

    Ash.create!(Campaign, %{
      tag: tag,
      model: model,
      time_budget: time_budget,
      base_config: base_config
    })
  end

  def get_campaign(tag) do
    Campaign
    |> Ash.Query.filter(tag == ^tag)
    |> Ash.read_one()
  end

  def get_campaign!(tag) do
    case get_campaign(tag) do
      {:ok, run} -> run
      {:error, reason} -> raise "Campaign '#{tag}' not found: #{inspect(reason)}"
    end
  end

  def get_campaign_by_id(id) do
    case Ash.get(Campaign, id) do
      {:ok, run} -> {:ok, run}
      {:error, _} -> {:ok, nil}
    end
  end

  def active_campaign do
    Campaign
    |> Ash.Query.filter(status == :running)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  def pause_campaign(run) do
    Ash.update!(run, %{status: :paused}, action: :update_status)
  end

  def resume_campaign(run) do
    Ash.update!(run, %{status: :running}, action: :update_status)
  end

  def update_campaign_model(run, model) do
    Ash.update!(run, %{model: model}, action: :update_status)
  end

  def update_campaign_best(run, experiment_id) do
    Ash.update!(run, %{best_trial_id: experiment_id}, action: :update_status)
  end

  # --- Trial CRUD (SQLite-backed) ---

  def all_trials(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  def get_trial(version_id) do
    Trial
    |> Ash.Query.filter(version_id == ^version_id)
    |> Ash.read_one()
  end

  def count_trials(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id)
    |> Ash.count!()
  end

  def best_trial(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id and kept == true and not is_nil(final_loss))
    |> Ash.Query.sort(final_loss: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
  end

  def kept_trials(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id and kept == true and not is_nil(code))
    |> Ash.Query.sort(final_loss: :asc)
    |> Ash.read!()
  end

  def record_trial(attrs) do
    Ash.create!(Trial, attrs, action: :record)
  end

  def complete_trial(experiment, attrs) do
    Ash.update!(experiment, attrs, action: :complete)
  end

  # --- Module cache (ETS, rebuilt on resume) ---

  def get_module(version_id) do
    case :ets.lookup(@modules_table, version_id) do
      [{^version_id, module}] -> {:ok, module}
      [] -> :not_loaded
    end
  rescue
    ArgumentError -> :not_loaded
  end

  def cache_module(version_id, module) do
    :ets.insert(@modules_table, {version_id, module})
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Reload a module from its stored source code.
  Used when resuming a run — the BEAM doesn't persist compiled modules.
  """
  def reload_module(experiment) do
    if experiment.code do
      code = Loader.inject_version_id(experiment.code, experiment.version_id)
      case Loader.load(experiment.version_id, code) do
        {:ok, module} ->
          cache_module(experiment.version_id, module)
          {:ok, module}
        {:error, reason} ->
          Logger.warning("Failed to reload v_#{experiment.version_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :no_code}
    end
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    :ets.new(@modules_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end
end
