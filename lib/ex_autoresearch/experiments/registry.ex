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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Campaign management ---

  @spec start_campaign(String.t(), keyword()) :: Campaign.t()
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

  @spec get_campaign(String.t()) :: {:ok, Campaign.t() | nil} | {:error, term()}
  def get_campaign(tag) do
    Campaign
    |> Ash.Query.filter(tag == ^tag)
    |> Ash.read_one()
  end

  @spec get_campaign!(String.t()) :: Campaign.t()
  def get_campaign!(tag) do
    case get_campaign(tag) do
      {:ok, run} -> run
      {:error, reason} -> raise "Campaign '#{tag}' not found: #{inspect(reason)}"
    end
  end

  @spec get_campaign_by_id(String.t()) :: {:ok, Campaign.t() | nil}
  def get_campaign_by_id(id) do
    case Ash.get(Campaign, id) do
      {:ok, run} -> {:ok, run}
      {:error, _} -> {:ok, nil}
    end
  end

  @spec active_campaign() :: {:ok, Campaign.t() | nil} | {:error, term()}
  def active_campaign do
    Campaign
    |> Ash.Query.filter(status == :running)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one()
  end

  @spec pause_campaign(Campaign.t()) :: Campaign.t()
  def pause_campaign(run) do
    Ash.update!(run, %{status: :paused}, action: :update_status)
  end

  @spec resume_campaign(Campaign.t()) :: Campaign.t()
  def resume_campaign(run) do
    Ash.update!(run, %{status: :running}, action: :update_status)
  end

  @spec update_campaign_model(Campaign.t(), String.t()) :: Campaign.t()
  def update_campaign_model(run, model) do
    Ash.update!(run, %{model: model}, action: :update_status)
  end

  @spec update_campaign_best(Campaign.t(), String.t()) :: Campaign.t()
  def update_campaign_best(run, experiment_id) do
    Ash.update!(run, %{best_trial_id: experiment_id}, action: :update_status)
  end

  # --- Trial CRUD (SQLite-backed) ---

  @spec all_trials(String.t()) :: [Trial.t()]
  def all_trials(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  @spec get_trial(String.t()) :: {:ok, Trial.t() | nil} | {:error, term()}
  def get_trial(version_id) do
    Trial
    |> Ash.Query.filter(version_id == ^version_id)
    |> Ash.read_one()
  end

  @spec count_trials(String.t()) :: non_neg_integer()
  def count_trials(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id)
    |> Ash.count!()
  end

  @spec best_trial(String.t()) :: Trial.t() | nil
  def best_trial(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id and kept == true and not is_nil(final_loss))
    |> Ash.Query.sort(final_loss: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
  end

  @spec kept_trials(String.t()) :: [Trial.t()]
  def kept_trials(campaign_id) do
    Trial
    |> Ash.Query.filter(campaign_id == ^campaign_id and kept == true and not is_nil(code))
    |> Ash.Query.sort(final_loss: :asc)
    |> Ash.read!()
  end

  @spec record_trial(map()) :: Trial.t()
  def record_trial(attrs) do
    Ash.create!(Trial, attrs, action: :record)
  end

  @spec complete_trial(Trial.t(), map()) :: Trial.t()
  def complete_trial(experiment, attrs) do
    Ash.update!(experiment, attrs, action: :complete)
  end

  # --- Module cache (ETS, rebuilt on resume) ---

  @spec get_module(String.t()) :: {:ok, module()} | :not_loaded
  def get_module(version_id) do
    case :ets.lookup(@modules_table, version_id) do
      [{^version_id, module}] -> {:ok, module}
      [] -> :not_loaded
    end
  rescue
    ArgumentError -> :not_loaded
  end

  @spec cache_module(String.t(), module()) :: true | :ok
  def cache_module(version_id, module) do
    :ets.insert(@modules_table, {version_id, module})
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Reload a module from its stored source code.
  Used when resuming a run — the BEAM doesn't persist compiled modules.
  """
  @spec reload_module(Trial.t()) :: {:ok, module()} | {:error, term()}
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
