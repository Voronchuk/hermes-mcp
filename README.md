# Hermes MCP

[![hex.pm](https://img.shields.io/hexpm/v/hermes_mcp.svg)](https://hex.pm/packages/hermes_mcp)
[![docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/hermes_mcp)
[![ci](https://github.com/cloudwalk/hermes-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/cloudwalk/hermes-mcp/actions/workflows/ci.yml)

> [!WARNING]
>
> This library is under active development, may expect breaking changes

A high-performance Model Context Protocol (MCP) implementation in Elixir.

## Overview

Hermes MCP is a comprehensive Elixir SDK for the [Model Context Protocol](https://spec.modelcontextprotocol.io/), aiming to provide complete client and server implementations. The library leverages Elixir's exceptional concurrency model and fault tolerance capabilities to deliver a robust MCP experience.

Currently, Hermes MCP offers a feature-complete client implementation conforming to the MCP 2024-11-05 specification. Server-side components are planned for future releases.

## Roadmap

### Current Status

- [x] Complete client implementation (MCP 2024-11-05)
- [x] Multiple transport options (STDIO, HTTP/SSE, and WebSocket)
- [x] Built-in connection supervision and automatic recovery
- [x] Comprehensive capability negotiation
- [x] Progress tracking and cancellation support
- [x] Structured logging system

### Upcoming

- [ ] Client support for MCP 2025-03-26 specification
  - Authorization framework (OAuth 2.1)
  - Streamable HTTP transport
  - JSON-RPC batch operations
  - Enhanced tool annotations

- [x] Server Implementation
  - STDIO transport
  - HTTP/SSE transport
  - Streamable HTTP transport
  - Support for resources, tools, and prompts

- [x] Sample Implementations
  - Reference servers
  - Integration examples with popular Elixir libraries

For a more detailed roadmap, see [ROADMAP.md](./ROADMAP.md).

## Installation

### Library Usage

Add Hermes MCP to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:hermes_mcp, "~> 0.5"}  # x-release-please-version
  ]
end
```

## Quick Start

### Interactive Testing

Hermes MCP provides interactive tools for testing MCP servers with a user-friendly CLI.

#### Using the CLI Binary:

Download the appropriate binary for your platform from the [GitHub releases page](https://github.com/cloudwalk/hermes-mcp/releases).

```bash
# Test an SSE server
hermes_cli --transport sse --base-url="http://localhost:8000" --base-path="/mcp"

# Test a WebSocket server
hermes_cli --transport websocket --base-url="http://localhost:8000" --base-path="/mcp" --ws-path="/ws"

# Test a local process via STDIO
hermes_cli --transport stdio --command="mcp" --args="run,path/to/server.py"
```

#### Using Mix Tasks (For Elixir Developers):

```bash
# Test an SSE server
mix hermes.sse.interactive --base-url="http://localhost:8000" --base-path="/mcp"

# Test a WebSocket server
mix hermes.websocket.interactive --base-url="http://localhost:8000" --base-path="/mcp" --ws-path="/ws"

# Test a local process via STDIO
mix hermes.stdio.interactive --command="mcp" --args="run,path/to/server.py"
```

These interactive shells provide commands for listing and calling tools, exploring prompts, and accessing resources.

### Setting up a Server

```elixir
# lib/my_app/server/tools/greet.ex
defmodule MyApp.Server.Tools.Greet do
  @moduledoc "Tool to greet someone"

  use Hermes.Server.Component, type: :tool

  alias Hermes.MCP.Error
  alias Hermes.Server.Response

  schema do
    %{name: {:required, :string}}
  end

  @impl true
  def execute(%{name: name}, frame) do
    case name do
      "mcp" -> {:reply, Response.text(Response.tool(), "Hello MCP!"), frame}
      "domain-error" -> {:reply, Response.error(Response.tool(), "we dont like it"), frame}
      _ -> {:error, Error.protocol(:invalid_params), frame}
    end
  end
end

# lib/my_app/server.ex
defmodule MyApp.Server do
  use Hermes.Server, name: "my server", version: "1.0.0", capabilities: [:tools]

  def start_link(opts) do
    Hermes.Server.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok, frame) do
    {:ok, frame}
  end
end

# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # handle processes names, you can customize via `Hermes.Server.Registry.Adapter`
      Hermes.Server.Registry,
      
      # start server using stdio
      {MyApp.Server, transport: :stdio}
    ]
    
    opts = [strategy: :one_for_all, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Setting up a Client

> [!IMPORTANT]
> **Process Startup Order**: Always start the client process before the transport process. The client hibernates waiting for the transport's `:initialize` message, so this order prevents race conditions during initialization.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # IMPORTANT: Start the client first - it will hibernate waiting for transport's :initialize message
      {Hermes.Client, [
        name: MyApp.MCPClient,
        transport: [layer: Hermes.Transport.STDIO, name: MyApp.MCPTransport],
        client_info: %{
          "name" => "MyApp",
          "version" => "1.0.0"
        },
        capabilities: %{
          "roots" => %{"listChanged" => true},
          "sampling" => %{}
        }
      ]},
      
      # Start the transport after the client
      {Hermes.Transport.STDIO, [
        name: MyApp.MCPTransport,
        client: MyApp.MCPClient, 
        command: "mcp",
        args: ["run", "path/to/server.py"]
      ]}
    ]
    
    opts = [strategy: :one_for_all, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Making Client Requests

```elixir
# Call a tool
{:ok, result} = Hermes.Client.call_tool(MyApp.MCPClient, "example_tool", %{"param" => "value"})

# Handle errors properly
case Hermes.Client.call_tool(MyApp.MCPClient, "unavailable_tool", %{}) do
  {:ok, %Hermes.MCP.Response{}} ->
    # Handle successful result
    
  {:error, %Hermes.MCP.Error{} = err} ->
    # Handle error response
    IO.puts(inspect(err, pretty: true))
end
```

## Documentation

For detailed guides and examples, visit the [official documentation](https://hexdocs.pm/hermes_mcp)

## Why Hermes?

The library is named after Hermes, the Greek god of boundaries, communication, and commerce. This namesake reflects the core purpose of the Model Context Protocol: to establish standardized communication between AI applications and external tools.

Like Hermes who served as a messenger between gods and mortals, this library facilitates seamless interaction between Large Language Models and various data sources or tools.

## Local Development

```bash
# Setup the project
mix setup

# Run tests
mix test

# Code quality
mix lint

# Start development MCP servers
# Echo server (Python)
just echo-server
# Calculator server (Go)
just calculator-server
```

The MCP servers in `priv/dev` require:
- Python 3.11+ with uv (for echo server)
- Go 1.21+ (for calculator server)

See [CONTRIBUTING.md](./CONTRIBUTING.md) for detailed contribution guidelines.

## License

Hermes MCP is released under the MIT License. See [LICENSE](./LICENSE) for details.
