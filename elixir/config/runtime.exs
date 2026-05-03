import Config

# `runtime.exs` is loaded at boot for every environment. Use
# `config_env()` to scope production-only overrides; dev/test inherit
# the defaults from `config.exs` unless explicitly overridden here.

if config_env() == :prod do
  secret_key_base =
    System.get_env("SYMPHONY_SECRET_KEY_BASE") ||
      raise """
      SYMPHONY_SECRET_KEY_BASE environment variable is not set.
      Generate one with: `mix phx.gen.secret` (a 64+ byte string).

      LiveView sockets, session cookies, and CSRF tokens are signed
      with this key. A leaked or hardcoded value defeats every
      session-bound authentication mechanism, so production deploys
      must always provide a per-environment secret here.
      """

  config :symphony_elixir, SymphonyElixirWeb.Endpoint,
    secret_key_base: secret_key_base
end

# `SYMPHONY_ALLOWED_ORIGINS` overrides the default loopback allowlist
# in `config.exs`. Use a comma-separated list:
#
#   SYMPHONY_ALLOWED_ORIGINS="//symphony.example.com,//ops.example.com"
#
# Setting it to "*" disables origin checking; this is intentionally
# undocumented because it re-introduces the vulnerability that the
# allowlist exists to close.
if origins = System.get_env("SYMPHONY_ALLOWED_ORIGINS") do
  parsed =
    origins
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if parsed != [] do
    config :symphony_elixir, SymphonyElixirWeb.Endpoint, check_origin: parsed
  end
end
