defmodule Hermes.Server.Transport.StreamableHTTP.Supervisor do
  @moduledoc """
  Supervisor for StreamableHTTP transport components.

  This supervisor manages the lifecycle of the StreamableHTTP transport
  process and any associated HTTP server components.
  """

  use Supervisor

  @doc """
  Starts the StreamableHTTP supervisor.

  ## Options
    * `:transport` - Configuration for the StreamableHTTP transport
    * `:registry` - Registry for process registration
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    # Transform the options to match what StreamableHTTP expects
    transport_opts = 
      opts
      |> Keyword.put(:name, opts[:transport_name])
      |> Keyword.delete(:transport_name)

    children = [
      {Hermes.Server.Transport.StreamableHTTP, transport_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end