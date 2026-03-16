defmodule ExAutoresearch.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    worker_only? = System.get_env("WORKER_ONLY") == "1"

    children =
      [
        ExAutoresearchWeb.Telemetry,
        ExAutoresearch.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:ex_autoresearch, :ecto_repos), skip: skip_migrations?()},
        {Oban,
         AshOban.config(
           Application.fetch_env!(:ex_autoresearch, :ash_domains),
           Application.fetch_env!(:ex_autoresearch, Oban)
         )},
        {DNSCluster, query: Application.get_env(:ex_autoresearch, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ExAutoresearch.PubSub},
        ExAutoresearch.Experiments.Registry,
        ExAutoresearch.Cluster
      ] ++
        if worker_only? do
          # Worker nodes only run training infrastructure — no LLM, no web
          []
        else
          [
            ExAutoresearch.Agent.LLM,
            ExAutoresearch.Training.Trainer,
            ExAutoresearch.Agent.Researcher
          ] ++ cuda_worker_children() ++ [ExAutoresearchWeb.Endpoint]
        end

    opts = [strategy: :one_for_one, name: ExAutoresearch.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExAutoresearchWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("SKIP_MIGRATIONS") == "true"
  end

  # Auto-spawn CUDA worker if the CUDA build and hermetic libs exist.
  # Worker sname is derived from main node: ex_autoresearch → ex_autoresearch_cuda
  defp cuda_worker_children do
    project_dir = File.cwd!()
    cuda_nif = Path.join(project_dir, "_build/cuda/lib/exla/priv/libexla.so")
    cuda_libs = Path.join(project_dir, "_build/cuda_libs")
    has_nvidia? = System.find_executable("nvidia-smi") != nil

    if has_nvidia? and File.exists?(cuda_nif) and File.dir?(cuda_libs) do
      main_sname = node() |> Atom.to_string() |> String.split("@") |> List.first()
      worker_name = "#{main_sname}_cuda"

      [
        {ExAutoresearch.Cluster.LocalWorker,
         name: worker_name, gpu_target: "cuda", build_path: "_build/cuda"}
      ]
    else
      []
    end
  end
end
