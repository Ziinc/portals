import Config

config :hello_live, HelloLiveWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: String.duplicate("hello_live_example_only_secret_", 3),
  live_view: [signing_salt: "hello_live"],
  render_errors: [formats: [html: HelloLiveWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

if config_env() == :test do
  config :hello_live, HelloLiveWeb.Endpoint, http: [port: 4002], server: false
  config :logger, level: :warning
end
