defmodule HelloLiveWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :hello_live

  @session_options [
    store: :cookie,
    key: "_hello_live_key",
    signing_salt: "hello_live",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # No asset pipeline: serve the prebuilt Phoenix and LiveView clients
  # straight from their packages.
  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/assets/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Session, @session_options
  plug HelloLiveWeb.Router
end
