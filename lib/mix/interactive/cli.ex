defmodule Mix.Interactive.CLI do
  @moduledoc """
  Standalone CLI application for Hermes MCP interactive shells.

  This module serves as the entry point for the standalone binary compiled with Burrito.
  It can start SSE, WebSocket, or STDIO interactive shells based on command-line arguments.
  """

  alias Hermes.Client
  alias Hermes.Transport.SSE
  alias Hermes.Transport.STDIO
  alias Hermes.Transport.WebSocket
  alias Mix.Interactive.Shell
  alias Mix.Interactive.UI

  @version Mix.Project.config()[:version]

  @doc """
  Main entry point for the standalone CLI application.
  """
  def main(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          transport: :string,
          base_url: :string,
          base_path: :string,
          sse_path: :string,
          ws_path: :string,
          command: :string,
          args: :string,
          verbose: :count
        ],
        aliases: [t: :transport, c: :command, v: :verbose]
      )

    verbose_count = opts[:verbose] || 0
    log_level = get_log_level_from_verbose(verbose_count)
    configure_logger_with_metadata(log_level)

    transport = opts[:transport] || "sse"

    case transport do
      "sse" ->
        run_sse_interactive(opts)

      "websocket" ->
        run_websocket_interactive(opts)

      "stdio" ->
        run_stdio_interactive(opts)

      _ ->
        IO.puts("""
        #{UI.colors().error}ERROR: Unknown transport type "#{transport}"
        Usage: hermes-mcp --transport [sse|websocket|stdio] [options]

        Available transports:
          sse       - SSE transport implementation
          websocket - WebSocket transport implementation
          stdio     - STDIO transport implementation

        Run with --help for more information#{UI.colors().reset}
        """)

        System.halt(1)
    end
  end

  defp run_sse_interactive(opts) do
    server_options = Keyword.put_new(opts, :base_url, "http://localhost:8000")
    server_url = Path.join(server_options[:base_url], server_options[:base_path] || "")

    IO.puts(UI.header("HERMES MCP SSE INTERACTIVE"))

    children = [
      # Start client first - it will hibernate waiting for transport's :initialize message
      {Client,
       name: :sse_test,
       transport: [layer: SSE],
       client_info: %{
         "name" => "Hermes.CLI.SSE",
         "version" => "1.0.0"
       }},
      {SSE, client: :sse_test, server: server_options}
    ]

    Supervisor.start_link(children, strategy: :one_for_all)

    sse = Process.whereis(SSE)
    IO.puts("#{UI.colors().info}Connecting to SSE server at: #{server_url}#{UI.colors().reset}\n")
    check_sse_connection(sse)

    client = Process.whereis(:sse_test)
    IO.puts("#{UI.colors().info}• Starting client connection...#{UI.colors().reset}")
    check_client_connection(client)

    IO.puts("\nType #{UI.colors().command}help#{UI.colors().reset} for available commands\n")

    Shell.loop(client)
  end

  defp run_websocket_interactive(opts) do
    server_options = Keyword.put_new(opts, :base_url, "http://localhost:8000")
    server_url = Path.join(server_options[:base_url], server_options[:base_path] || "")

    IO.puts(UI.header("HERMES MCP WEBSOCKET INTERACTIVE"))

    children = [
      # Start client first - it will hibernate waiting for transport's :initialize message
      {Client,
       name: :websocket_test,
       transport: [layer: WebSocket],
       client_info: %{
         "name" => "Hermes.CLI.WebSocket",
         "version" => "1.0.0"
       }},
      {WebSocket, client: :websocket_test, server: server_options}
    ]

    Supervisor.start_link(children, strategy: :one_for_all)

    ws = Process.whereis(WebSocket)
    IO.puts("#{UI.colors().info}Connecting to WebSocket server at: #{server_url}#{UI.colors().reset}\n")
    check_websocket_connection(ws)

    client = Process.whereis(:websocket_test)
    IO.puts("#{UI.colors().info}• Starting client connection...#{UI.colors().reset}")
    check_client_connection(client)

    IO.puts("\nType #{UI.colors().command}help#{UI.colors().reset} for available commands\n")

    Shell.loop(client)
  end

  defp run_stdio_interactive(opts) do
    cmd = opts[:command] || "mcp"
    args = String.split(opts[:args] || "run,priv/dev/echo/index.py", ",", trim: true)

    IO.puts(UI.header("HERMES MCP STDIO INTERACTIVE"))
    IO.puts("#{UI.colors().info}Starting STDIO interaction MCP server#{UI.colors().reset}\n")

    if cmd == "mcp" and not (!!System.find_executable("mcp")) do
      IO.puts(
        "#{UI.colors().error}Error: mcp executable not found in PATH, maybe you need to activate venv#{UI.colors().reset}"
      )

      System.halt(1)
    end

    {:ok, _} =
      STDIO.start_link(
        command: cmd,
        args: args,
        client: :stdio_test
      )

    IO.puts("#{UI.colors().success}✓ STDIO transport started#{UI.colors().reset}")

    {:ok, client} =
      Client.start_link(
        name: :stdio_test,
        transport: [layer: STDIO],
        client_info: %{
          "name" => "Hermes.CLI.STDIO",
          "version" => "1.0.0"
        },
        capabilities: %{
          "roots" => %{
            "listChanged" => true
          },
          "sampling" => %{}
        }
      )

    IO.puts("#{UI.colors().info}• Starting client connection...#{UI.colors().reset}")
    check_client_connection(client)

    IO.puts("\nType #{UI.colors().command}help#{UI.colors().reset} for available commands\n")

    Shell.loop(client)
  end

  def check_client_connection(client, attempt \\ 5)

  def check_client_connection(_client, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ Server connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_client_connection(client, attempt) do
    :timer.sleep(200 * attempt)

    if cap = Client.get_server_capabilities(client) do
      IO.puts("#{UI.colors().info}Server capabilities: #{inspect(cap, pretty: true)}#{UI.colors().reset}")

      IO.puts("#{UI.colors().success}✓ Successfully connected to server#{UI.colors().reset}")
    else
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")
      check_client_connection(client, attempt - 1)
    end
  end

  def check_sse_connection(sse, attempt \\ 3)

  def check_sse_connection(_sse, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ SSE connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_sse_connection(sse, attempt) do
    :timer.sleep(500)

    state = :sys.get_state(sse)

    if state[:message_url] == nil do
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")
      check_sse_connection(sse, attempt - 1)
    else
      IO.puts(
        "#{UI.colors().info}SSE connection:\n\s\s- sse stream url: #{state[:sse_url]}\n\s\s- message url: #{state[:message_url]}#{UI.colors().reset}"
      )

      IO.puts("#{UI.colors().success}✓ Successfully connected via SSE#{UI.colors().reset}")
    end
  end

  def check_websocket_connection(ws, attempt \\ 3)

  def check_websocket_connection(_ws, attempt) when attempt <= 0 do
    IO.puts("#{UI.colors().error}✗ WebSocket connection not established#{UI.colors().reset}")

    IO.puts("#{UI.colors().info}Use the 'initialize' command to retry connection#{UI.colors().reset}")
  end

  def check_websocket_connection(ws, attempt) do
    :timer.sleep(500)

    state = :sys.get_state(ws)

    if state[:stream_ref] == nil do
      IO.puts("#{UI.colors().warning}! Waiting for server connection...#{UI.colors().reset}")
      check_websocket_connection(ws, attempt - 1)
    else
      IO.puts("#{UI.colors().info}WebSocket connection:\n\s\s- ws url: #{state[:ws_url]}#{UI.colors().reset}")

      IO.puts("#{UI.colors().success}✓ Successfully connected via WebSocket#{UI.colors().reset}")
    end
  end

  @doc false
  def show_help do
    colors = UI.colors()

    IO.puts("""
    #{colors.info}Hermes MCP Client v#{@version}#{colors.reset}
    #{colors.success}A command-line MCP client for interacting with MCP servers#{colors.reset}

    #{colors.info}USAGE:#{colors.reset}
      hermes-mcp [OPTIONS]

    #{colors.info}OPTIONS:#{colors.reset}
      #{colors.command}-h, --help#{colors.reset}             Show this help message and exit
      #{colors.command}-t, --transport TYPE#{colors.reset}   Transport type to use (sse|websocket|stdio) [default: sse]
      #{colors.command}-v#{colors.reset}                     Set log level: -v (warning), -vv (info), -vvv (debug) [default: error]
      
    #{colors.info}SSE TRANSPORT OPTIONS:#{colors.reset}
      #{colors.command}--base-url URL#{colors.reset}         Base URL for SSE server [default: http://localhost:8000]
      #{colors.command}--base-path PATH#{colors.reset}       Base path for the SSE server
      #{colors.command}--sse-path PATH#{colors.reset}        Path for SSE endpoint

    #{colors.info}WEBSOCKET TRANSPORT OPTIONS:#{colors.reset}
      #{colors.command}--base-url URL#{colors.reset}         Base URL for WebSocket server [default: http://localhost:8000]
      #{colors.command}--base-path PATH#{colors.reset}       Base path for the WebSocket server
      #{colors.command}--ws-path PATH#{colors.reset}         Path for WebSocket endpoint [default: /ws]

    #{colors.info}STDIO TRANSPORT OPTIONS:#{colors.reset}
      #{colors.command}-c, --command CMD#{colors.reset}      Command to execute [default: mcp]
      #{colors.command}--args ARGS#{colors.reset}            Comma-separated arguments for the command
                               [default: run,priv/dev/echo/index.py]

    #{colors.info}EXAMPLES:#{colors.reset}
      # Connect to a local SSE server
      hermes-mcp 

      # Connect to a remote SSE server
      hermes-mcp --transport sse --base-url https://remote-server.example.com

      # Connect to a WebSocket server
      hermes-mcp --transport websocket --base-url http://localhost:8000 --ws-path /mcp/ws

      # Run a local MCP server with stdio
      hermes-mcp --transport stdio --command ./my-mcp-server --args arg1,arg2

    #{colors.info}INTERACTIVE COMMANDS:#{colors.reset}
      Once connected, type 'help' to see available interactive commands.
    """)
  end

  # Helper functions for log levels
  defp get_log_level_from_verbose(count) do
    case count do
      0 -> :error
      1 -> :warning
      2 -> :info
      _ -> :debug
    end
  end

  defp configure_logger_with_metadata(log_level) do
    metadata = Logger.metadata()
    Logger.configure(level: log_level)
    Logger.metadata(metadata)
  end
end
