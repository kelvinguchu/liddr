defmodule Liddr.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    optional_children =
      [Liddr.Location.Redis.child_spec([])]
      |> Enum.reject(&is_nil/1)

    children =
      [
        LiddrWeb.Telemetry,
        Liddr.Repo,
        {Oban, Application.fetch_env!(:liddr, Oban)},
        {DNSCluster, query: Application.get_env(:liddr, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Liddr.PubSub}
      ] ++
        optional_children ++
        [
          {Registry, keys: :unique, name: Liddr.Rides.DispatchRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: Liddr.Rides.DispatchSupervisor},
          # Start a worker by calling: Liddr.Worker.start_link(arg)
          # {Liddr.Worker, arg},
          # Start to serve requests, typically the last entry
          LiddrWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Liddr.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LiddrWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
