defmodule HelloLive.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = HelloLive.Languages.child_specs() ++ [HelloLiveWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: HelloLive.Supervisor)
  end
end
