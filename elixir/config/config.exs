import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  # Dev/test default. Production must set `SYMPHONY_SECRET_KEY_BASE`;
  # `config/runtime.exs` overwrites this value in :prod or raises if the
  # env var is missing. The literal-`s`*64 default is fine for tests
  # (no real session signing happens) but is never used in production.
  secret_key_base: String.duplicate("s", 64),
  # Loopback-only allowlist by default. Production deployments should
  # set `SYMPHONY_ALLOWED_ORIGINS` (comma-separated) and `runtime.exs`
  # picks it up. `check_origin: false` is never the right answer — it
  # disables the WebSocket origin check entirely, so any browser tab
  # that can reach the bound interface could connect to the LiveView
  # socket.
  check_origin: ["//127.0.0.1", "//localhost"],
  server: false
