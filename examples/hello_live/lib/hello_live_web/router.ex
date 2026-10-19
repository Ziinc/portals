defmodule HelloLiveWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {HelloLiveWeb.Layouts, :root}
  end

  scope "/" do
    pipe_through :browser
    live "/", HelloLiveWeb.HelloLive
  end
end
