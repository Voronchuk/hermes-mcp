defmodule Hermes.Server.Supervisor do
  @moduledoc """
  Supervisor for MCP server processes.

  This supervisor manages the lifecycle of an MCP server, including:
  - The Base server process that handles MCP protocol
  - The transport layer (STDIO, StreamableHTTP, or SSE)
  - Session supervisors for StreamableHTTP transport

  The supervision strategy is `:one_for_all`, meaning if any child
  process crashes, all processes are restarted to maintain consistency.

  ## Conditional Startup

  The supervisor intelligently handles startup based on transport type:

  - **STDIO transport**: Always starts
  - **StreamableHTTP/SSE transport**: Only starts when an HTTP server is running
    (Phoenix with `:serve_endpoints` or Bandit/Cowboy started)

  This prevents MCP servers from starting in environments where they can't
  function properly (e.g., during migrations, tests, or non-web Mix tasks).

  You can override this behavior with the `:start` option:
  ```elixir
  # Force start even without HTTP server
  {MyServer, transport: {:streamable_http, start: true}}

  # Prevent start even with HTTP server
  {MyServer, transport: {:streamable_http, start: false}}
  ```

  ## Supervision Tree

  For STDIO transport:
  ```
  Supervisor
  ├── Base Server
  └── STDIO Transport
  ```

  For StreamableHTTP transport:
  ```
  Supervisor
  ├── Session.Supervisor
  ├── Base Server
  └── StreamableHTTP Transport
  ```
  """

  use Supervisor, restart: :permanent

  alias Hermes.Server.Base
  alias Hermes.Server.Session
  alias Hermes.Server.Transport.STDIO
  alias Hermes.Server.Transport.StreamableHTTP

  # TODO(zoedsoupe): need to implement backward compatibility with SSE/2024-05-11
  @type sse :: {:sse, keyword()}
  @type stream_http :: {:streamable_http, keyword()}

  @type transport :: :stdio | stream_http | sse | StubTransport

  @type start_option :: {:transport, transport} | {:name, Supervisor.name()}

  @doc """
  Starts the server supervisor.

  ## Parameters

    * `server` - The module implementing `Hermes.Server.Behaviour`
    * `init_arg` - Argument passed to the server's `init/1` callback
    * `opts` - Options including:
      * `:transport` - Transport configuration (required)
      * `:name` - Supervisor name (optional, defaults to registered name)
      * `:registry` - The custom registry to use to manage processes names (defaults to `Hermes.Server.Registry`)

  ## Examples

      # Start with STDIO transport
      Hermes.Server.Supervisor.start_link(MyServer, [], transport: :stdio)

      # Start with StreamableHTTP transport
      Hermes.Server.Supervisor.start_link(MyServer, [],
        transport: {:streamable_http, port: 8080}
      )
  """
  @spec start_link(server :: module, init_arg :: term, list(start_option)) :: Supervisor.on_start()
  def start_link(server, init_arg, opts) when is_atom(server) and is_list(opts) do
    registry = Keyword.get(opts, :registry, Hermes.Server.Registry)
    name = Keyword.get(opts, :name, registry.supervisor(server))
    opts = Keyword.merge(opts, module: server, init_arg: init_arg, registry: registry)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :module)
    transport = Keyword.fetch!(opts, :transport)
    init_arg = Keyword.fetch!(opts, :init_arg)
    registry = Keyword.fetch!(opts, :registry)

    if should_start?(transport) do
      {layer, transport_opts} = parse_transport_child(transport, server, registry)

      server_name = registry.server(server)
      server_transport = [layer: layer, name: transport_opts[:name]]

      server_opts = [
        module: server,
        name: server_name,
        transport: server_transport,
        init_arg: init_arg,
        registry: registry
      ]

      children = [
        {Session.Supervisor, server: server, registry: registry},
        {Base, server_opts},
        {layer, transport_opts}
      ]

      Supervisor.init(children, strategy: :one_for_all)
    else
      :ignore
    end
  end

  if Mix.env() == :test do
    defp parse_transport_child(StubTransport = kind, server, registry) do
      name = registry.transport(server, kind)
      opts = [name: name, server: server, registry: registry]
      {kind, opts}
    end
  end

  defp parse_transport_child(:stdio, server, registry) do
    name = registry.transport(server, :stdio)
    opts = [name: name, server: server, registry: registry]
    {STDIO, opts}
  end

  defp parse_transport_child({:streamable_http, opts}, server, registry) do
    name = registry.transport(server, :streamable_http)
    opts = Keyword.merge(opts, name: name, server: server, registry: registry)
    {StreamableHTTP, opts}
  end

  defp parse_transport_child({:sse, _opts}, _server, _), do: raise("unimplemented")

  if Mix.env() == :test do
    defp should_start?(StubTransport), do: true
  end

  defp should_start?(:stdio), do: true

  defp should_start?({transport, opts}) when transport in ~w(sse streamable_http)a do
    start? = Keyword.get(opts, :start)
    if is_nil(start?), do: http_server_running?(), else: start?
  end

  defp http_server_running? do
    phoenix_serving? = Application.get_env(:phoenix, :serve_endpoints)

    if is_nil(phoenix_serving?), do: true, else: phoenix_serving?
  end
end
