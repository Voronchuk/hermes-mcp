defmodule Hermes.Server.Transport.StreamableHTTP.SessionRegistry do
  @moduledoc """
  Session registry for StreamableHTTP transport.

  This module manages session state and connections for the StreamableHTTP
  transport, tracking SSE connections and session metadata.
  """

  use GenServer

  @doc """
  Starts the session registry.

  ## Options
    * `:name` - Name for the registry GenServer process
    * `:table_name` - Name for the ETS table storing session data
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a new session.
  """
  def register_session(registry, session_id, metadata \\ %{}) do
    GenServer.call(registry, {:register_session, session_id, metadata})
  end

  @doc """
  Unregisters a session.
  """
  def unregister_session(registry, session_id) do
    GenServer.call(registry, {:unregister_session, session_id})
  end

  @doc """
  Gets session information.
  """
  def get_session(registry, session_id) do
    GenServer.call(registry, {:get_session, session_id})
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, :streamable_http_sessions)
    table = :ets.new(table_name, [:set, :protected, :named_table])
    
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:register_session, session_id, metadata}, _from, state) do
    :ets.insert(state.table, {session_id, metadata})
    {:reply, :ok, state}
  end

  def handle_call({:unregister_session, session_id}, _from, state) do
    :ets.delete(state.table, session_id)
    {:reply, :ok, state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    case :ets.lookup(state.table, session_id) do
      [{^session_id, metadata}] -> {:reply, {:ok, metadata}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end
end