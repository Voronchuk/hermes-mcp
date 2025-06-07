defmodule Hermes.Server.Transport.StreamableHTTP do
  @moduledoc """
  StreamableHTTP transport implementation for MCP servers.

  This module provides an HTTP-based transport layer that supports multiple
  concurrent client sessions through Server-Sent Events (SSE). It enables
  web-based MCP clients to communicate with the server using standard HTTP
  protocols.

  ## Architecture

  The StreamableHTTP transport consists of three main components:

  1. **Transport Process** (this module) - Manages SSE connections and routes
     messages between clients and the server
  2. **Plug Module** (`Hermes.Server.Transport.StreamableHTTP.Plug`) - Handles
     HTTP endpoints for SSE connections and message submission
  3. **Supervisor** (`Hermes.Server.Transport.StreamableHTTP.Supervisor`) -
     Manages the Plug.Cowboy server lifecycle

  ## Features

  - Multiple concurrent client sessions
  - Server-Sent Events for real-time server-to-client communication
  - HTTP POST endpoint for client-to-server messages
  - Automatic session cleanup on disconnect
  - Integration with Phoenix/Plug applications

  ## Usage

  StreamableHTTP is typically started through the server supervisor:

      Hermes.Server.start_link(MyServer, [],
        transport: :streamable_http,
        streamable_http: [port: 4000]
      )

  For integration with existing Phoenix/Plug applications:

      # In your router
      forward "/mcp", Hermes.Server.Transport.StreamableHTTP.Plug,
        server: MyApp.MCPServer

  ## Message Flow

  1. Client connects to `/sse` endpoint, receives a session ID
  2. Client sends messages via POST to `/messages` with session ID header
  3. Server responses are pushed through the SSE connection
  4. Connection closes on client disconnect or server shutdown

  ## Configuration

  - `:port` - HTTP server port (default: 4000)
  - `:server` - The MCP server process to connect to
  - `:name` - Process registration name
  """

  @behaviour Hermes.Transport.Behaviour

  use GenServer

  import Peri

  alias Hermes.Logging
  alias Hermes.MCP.Message
  alias Hermes.Telemetry
  alias Hermes.Transport.Behaviour, as: Transport

  require Message

  @type t :: GenServer.server()

  @typedoc """
  StreamableHTTP transport options

  - `:server` - The server process (required)
  - `:name` - Name for registering the GenServer (required)
  """
  @type option ::
          {:server, GenServer.server()}
          | {:name, GenServer.name()}
          | GenServer.option()

  defschema :parse_options, [
    {:server, {:required, Hermes.get_schema(:process_name)}},
    {:name, {:required, {:custom, &Hermes.genserver_name/1}}}
  ]

  @doc """
  Starts the StreamableHTTP transport.
  """
  @impl Transport
  @spec start_link(Enumerable.t(option())) :: GenServer.on_start()
  def start_link(opts) do
    opts = parse_options!(opts)
    {name, opts} = Keyword.pop!(opts, :name)

    GenServer.start_link(__MODULE__, Map.new(opts), name: name)
  end

  @doc """
  Sends a message to the client via the active SSE connection.

  This function is used for server-initiated notifications.
  It will broadcast to all active SSE connections.

  ## Parameters
    * `transport` - The transport process
    * `message` - The message to send

  ## Returns
    * `:ok` if message was sent successfully
    * `{:error, reason}` otherwise
  """
  @impl Transport
  @spec send_message(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_message(transport, message) when is_binary(message) do
    GenServer.call(transport, {:send_message, message})
  end

  @doc """
  Creates a new session.

  ## Parameters
    * `transport` - The transport process

  ## Returns
    * `{:ok, session_id}` if session was created successfully
    * `{:error, reason}` otherwise
  """
  @spec create_session(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def create_session(transport) do
    GenServer.call(transport, :create_session)
  end

  @doc """
  Sets the SSE connection for a session.

  ## Parameters
    * `transport` - The transport process
    * `session_id` - The session ID
    * `sse_pid` - The SSE handler process

  ## Returns
    * `:ok` if connection was set successfully
    * `{:error, reason}` otherwise
  """
  @spec set_sse_connection(GenServer.server(), String.t(), pid()) :: :ok | {:error, term()}
  def set_sse_connection(transport, session_id, sse_pid) do
    GenServer.call(transport, {:set_sse_connection, session_id, sse_pid})
  end

  @doc """
  Looks up session information.

  ## Parameters
    * `transport` - The transport process
    * `session_id` - The session ID

  ## Returns
    * `{:ok, session_info}` if session exists
    * `{:error, :not_found}` otherwise
  """
  @spec lookup_session(GenServer.server(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def lookup_session(transport, session_id) do
    GenServer.call(transport, {:lookup_session, session_id})
  end

  @doc """
  Handles a message for a specific session.

  ## Parameters
    * `transport` - The transport process
    * `session_id` - The session ID
    * `message` - The message to handle

  ## Returns
    * `{:ok, response}` if message was handled successfully
    * `{:error, reason}` otherwise
  """
  @spec handle_message(GenServer.server(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def handle_message(transport, session_id, message) do
    GenServer.call(transport, {:handle_message, session_id, message})
  end

  @doc """
  Shuts down the transport connection.

  This terminates all active sessions managed by this transport.

  ## Parameters
    * `transport` - The transport process
  """
  @impl Transport
  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(transport) do
    GenServer.cast(transport, :shutdown)
  end

  @impl Transport
  def supported_protocol_versions do
    ["2024-11-05", "2025-03-26"]
  end

  @doc """
  Registers an SSE handler process for a session.

  Called by the Plug when establishing an SSE connection.
  The calling process becomes the SSE handler for the session.
  """
  @spec register_sse_handler(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def register_sse_handler(transport, session_id) do
    GenServer.call(transport, {:register_sse_handler, session_id, self()})
  end

  @doc """
  Unregisters an SSE handler process for a session.

  Called when the SSE connection is closed.
  """
  @spec unregister_sse_handler(GenServer.server(), String.t()) :: :ok
  def unregister_sse_handler(transport, session_id) do
    GenServer.cast(transport, {:unregister_sse_handler, session_id})
  end

  @doc """
  Handles an incoming message and returns {:sse, response} if SSE handler exists.

  This allows the Plug to know whether to stream the response via SSE
  or return it as a regular HTTP response.
  """
  @spec handle_message_for_sse(GenServer.server(), String.t(), map()) ::
          {:ok, binary()} | {:sse, binary()} | {:error, term()}
  def handle_message_for_sse(transport, session_id, message) do
    GenServer.call(transport, {:handle_message_for_sse, session_id, message})
  end

  @doc """
  Gets the SSE handler process for a session.

  Returns the pid of the process handling SSE for this session,
  or nil if no SSE connection exists.
  """
  @spec get_sse_handler(GenServer.server(), String.t()) :: pid() | nil
  def get_sse_handler(transport, session_id) do
    GenServer.call(transport, {:get_sse_handler, session_id})
  end

  @doc """
  Routes a message to a specific session's SSE handler.

  Used for targeted server notifications to specific clients.
  """
  @spec route_to_session(GenServer.server(), String.t(), binary()) :: :ok | {:error, term()}
  def route_to_session(transport, session_id, message) do
    GenServer.call(transport, {:route_to_session, session_id, message})
  end

  # GenServer implementation

  @impl GenServer
  def init(%{server: server}) do
    Process.flag(:trap_exit, true)

    state = %{
      server: server,
      # Map of session_id => {pid, monitor_ref}
      sse_handlers: %{},
      # Map of session_id => session_metadata
      sessions: %{}
    }

    Logger.metadata(mcp_transport: :streamable_http, mcp_server: server)
    Logging.transport_event("starting", %{transport: :streamable_http, server: server})

    Telemetry.execute(
      Telemetry.event_transport_init(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, server: server}
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register_sse_handler, session_id, pid}, _from, state) do
    ref = Process.monitor(pid)

    sse_handlers = Map.put(state.sse_handlers, session_id, {pid, ref})

    Logging.transport_event("sse_handler_registered", %{
      session_id: session_id,
      handler_pid: inspect(pid)
    })

    {:reply, :ok, %{state | sse_handlers: sse_handlers}}
  end

  @impl GenServer
  def handle_call({:handle_message, session_id, message}, _from, state) do
    # Check if session exists first
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}
      
      session_metadata ->
        with {:ok, decoded_messages} <- Message.decode(message) do
          server = state.server
          
          # Handle both single message and array of messages
          decoded_message = case decoded_messages do
            [single_message] -> single_message
            _single_message when is_list(decoded_messages) -> {:error, :invalid_message_format}
            single_message -> single_message
          end

          case decoded_message do
            {:error, reason} ->
              {:reply, {:error, reason}, state}
            
            _ ->
              # Update last activity
              updated_metadata = Map.put(session_metadata, :last_activity, DateTime.utc_now())
              updated_sessions = Map.put(state.sessions, session_id, updated_metadata)
              updated_state = %{state | sessions: updated_sessions}
              
              if Message.is_notification(decoded_message) do
                GenServer.cast(server, {:notification, decoded_message, session_id})
                {:reply, {:ok, nil}, updated_state}
              else
                result = forward_request_to_server(server, decoded_message, session_id)
                {:reply, result, updated_state}
              end
          end
        else
          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl GenServer
  def handle_call({:handle_message_for_sse, session_id, message}, _from, state) do
    with {:ok, decoded_messages} <- Message.decode(message) do
      server = state.server
      
      # Handle both single message and array of messages
      decoded_message = case decoded_messages do
        [single_message] -> single_message
        _single_message when is_list(decoded_messages) -> {:error, :invalid_message_format}
        single_message -> single_message
      end

      case decoded_message do
        {:error, reason} ->
          {:reply, {:error, reason}, state}
        
        _ ->
          if Message.is_notification(decoded_message) do
            GenServer.cast(server, {:notification, decoded_message, session_id})
            {:reply, {:ok, nil}, state}
          else
            sse_handler? = Map.has_key?(state.sse_handlers, session_id)
            {:reply, forward_request_to_server(server, decoded_message, session_id, sse_handler?), state}
          end
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:get_sse_handler, session_id}, _from, state) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref} -> {:reply, pid, state}
      nil -> {:reply, nil, state}
    end
  end

  @impl GenServer
  def handle_call({:route_to_session, session_id, message}, _from, state) do
    case Map.get(state.sse_handlers, session_id) do
      {pid, _ref} ->
        send(pid, {:sse_message, message})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :no_sse_handler}, state}
    end
  end

  @impl GenServer
  def handle_call({:send_message, message}, _from, state) do
    if map_size(state.sse_handlers) == 0 do
      {:reply, {:error, :no_active_session}, state}
    else
      Logging.transport_event("broadcast_notification", %{
        message_size: byte_size(message),
        active_handlers: map_size(state.sse_handlers)
      })

      for {_session_id, {pid, _ref}} <- state.sse_handlers do
        send(pid, {:sse_message, message})
      end

      {:reply, :ok, state}
    end
  end

  def handle_call(:create_session, _from, state) do
    session_id = generate_session_id()
    now = DateTime.utc_now()
    session_metadata = %{
      session_id: session_id,
      server: state.server,
      created_at: System.system_time(:second),
      last_activity: now
    }
    sessions = Map.put(state.sessions, session_id, session_metadata)
    {:reply, {:ok, session_id}, %{state | sessions: sessions}}
  end

  def handle_call({:set_sse_connection, session_id, sse_pid}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      
      session_metadata ->
        ref = Process.monitor(sse_pid)
        sse_handlers = Map.put(state.sse_handlers, session_id, {sse_pid, ref})
        updated_metadata = Map.put(session_metadata, :sse_pid, sse_pid)
        sessions = Map.put(state.sessions, session_id, updated_metadata)
        {:reply, :ok, %{state | sse_handlers: sse_handlers, sessions: sessions}}
    end
  end

  def handle_call({:lookup_session, session_id}, _from, state) do
    case Map.get(state.sessions, session_id) do
      session_metadata when is_map(session_metadata) ->
        {:reply, {:ok, session_metadata}, state}
      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64(padding: false)
  end

  defp forward_request_to_server(server, message, session_id, has_sse_handler \\ false) do
    case GenServer.call(server, {:request, message, session_id}) do
      {:ok, response} when has_sse_handler ->
        {:sse, response}

      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logging.transport_event("server_error", %{reason: reason, session_id: session_id}, level: :error)
        {:error, reason}
    end
  catch
    :exit, reason ->
      Logging.transport_event("server_call_failed", %{reason: reason}, level: :error)
      {:error, :server_unavailable}
  end

  @impl GenServer
  def handle_cast({:unregister_sse_handler, session_id}, state) do
    sse_handlers =
      case Map.get(state.sse_handlers, session_id) do
        {_pid, ref} ->
          Process.demonitor(ref, [:flush])
          Map.delete(state.sse_handlers, session_id)

        nil ->
          state.sse_handlers
      end

    {:noreply, %{state | sse_handlers: sse_handlers}}
  end

  @impl GenServer
  def handle_cast(:shutdown, state) do
    Logging.transport_event("shutdown", %{transport: :streamable_http}, level: :info)

    for {_session_id, {pid, _ref}} <- state.sse_handlers do
      send(pid, :close_sse)
    end

    Telemetry.execute(
      Telemetry.event_transport_disconnect(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, reason: :shutdown}
    )

    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    sse_handlers =
      state.sse_handlers
      |> Enum.reject(fn {_session_id, {handler_pid, monitor_ref}} ->
        handler_pid == pid and monitor_ref == ref
      end)
      |> Map.new()

    Logging.transport_event("sse_handler_down", %{handler_pid: inspect(pid)})

    {:noreply, %{state | sse_handlers: sse_handlers}}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, _state) do
    Telemetry.execute(
      Telemetry.event_transport_terminate(),
      %{system_time: System.system_time()},
      %{transport: :streamable_http, reason: reason}
    )

    :ok
  end
end
