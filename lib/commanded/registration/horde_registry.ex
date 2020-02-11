defmodule Commanded.Registration.HordeRegistry do
  import Commanded.Registration.HordeRegistry.Util
  require Logger

  @moduledoc """
  Process registration and distribution via [Horde](https://github.com/derekkraan/horde)

  In order to use this, you will need to update the following config values:

  ```
  config :commanded,
    registry: Commanded.Registration.HordeRegistry,
    aggregate_supervisor_mfa:
      {Horde.Supervisor, :start_link,
       [[name: Commanded.Aggregates.Supervisor, strategy: :one_for_one]]}
  ```

  You will also need to join the Supervisors together (connecting them via Distributed Erlang is not
  enough) via `Horde.Cluster` as documented. Starting a `Commanded.Registration.HordeRegistry.Linker`
  in your supervision tree will accomplish this, and has the added benefit of continually checking
  the cluster for new members and joining them.
  """

  @behaviour Commanded.Registration.Adapter

  @impl Commanded.Registration.Adapter
  def child_spec(application, _config) do
    name = Module.concat([application, HordeRegistry])
    {:ok, [Horde.Registry.child_spec(name: name, keys: :unique)], %{registry_name: name}}
  end

  @impl Commanded.Registration.Adapter
  def supervisor_child_spec(_adapter_meta, module, _args) do
    defaults = [
      strategy: :one_for_one,
      distribution_strategy: Horde.UniformDistribution,
      name: module,
      members: get_cluster_members(module)
    ]

    overrides = Application.get_env(:commanded_horde_registry, :supervisor_opts, [])
    opts = Keyword.merge(defaults, overrides)

    Horde.DynamicSupervisor.child_spec(opts)
  end

  @impl Commanded.Registration.Adapter
  def start_child(adapter_meta, name, supervisor, {module, args}) do
    via_name = via_tuple(adapter_meta, name)
    updated_args = Keyword.put(args, :name, via_name)

    fun = fn ->
      spec = Supervisor.child_spec({module, updated_args}, id: {module, name})
      Horde.DynamicSupervisor.start_child(supervisor, spec)
    end

    start(adapter_meta, name, fun)
  end

  @impl Commanded.Registration.Adapter
  def start_link(adapter_meta, name, supervisor, args) do
    via_name = via_tuple(adapter_meta, name)

    fun = fn -> GenServer.start_link(supervisor, args, name: via_name) end
    start(adapter_meta, name, fun)
  end

  @impl Commanded.Registration.Adapter
  def whereis_name(adapter_meta, name) do
    registry_name = registry_name(adapter_meta)

    case Horde.Registry.whereis_name({registry_name, name}) do
      pid when is_pid(pid) ->
        pid

      :undefined ->
        :undefined

      other ->
        Logger.warn("unexpected response from Horde.Registry.whereis_name/1: #{inspect(other)}")
        :undefined
    end
  end

  @impl Commanded.Registration.Adapter
  def via_tuple(adapter_meta, name) do
    registry_name = registry_name(adapter_meta)
    {:via, Horde.Registry, {registry_name, name}}
  end

  defp start(adapter_meta, name, func) do
    case func.() do
      {:error, {:already_started, nil}} ->
        case whereis_name(adapter_meta, name) do
          pid when is_pid(pid) -> {:ok, pid}
          _other -> {:error, :registered_but_dead}
        end

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:ok, pid}

      {:ok, nil} ->
        {:error, :received_ok_nil}

      reply ->
        reply
    end
  end

  defp registry_name(adapter_meta), do: Map.get(adapter_meta, :registry_name)
end
