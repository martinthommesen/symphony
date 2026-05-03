defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Authenticated pipeline for observability + control endpoints. The plug
  # rejects any request that does not match the configured bearer token, or
  # any request to a non-loopback bind when no token is configured. This
  # closes the legacy `/api/v1/refresh` auth bypass and brings read
  # endpoints under the same posture as the mutating routes.
  pipeline :control_auth do
    plug(SymphonyElixirWeb.Plugs.RequireBearer)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end

  # `/api/v1/health` stays public so capability discovery, monitoring
  # probes, and readiness checks work without a token.
  scope "/", SymphonyElixirWeb do
    get("/api/v1/health", ObservabilityApiController, :health)
  end

  # Authenticated handlers for the typed observability + control routes.
  # Anything mutating goes here; reads are also gated so a non-loopback
  # bind without a token can't enumerate operational data.
  scope "/", SymphonyElixirWeb do
    pipe_through(:control_auth)

    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/issues", ObservabilityApiController, :issues)
    get("/api/v1/issues/:issue_identifier", ObservabilityApiController, :issue)
    get("/api/v1/events", ObservabilityApiController, :events)
    get("/api/v1/events/stream", ObservabilityApiController, :event_stream)
    get("/api/v1/analytics", ObservabilityApiController, :analytics)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    post("/api/v1/control/:command", ObservabilityApiController, :control)
  end

  # Method-not-allowed fallbacks for the typed paths above. These must
  # be declared BEFORE the dynamic `/api/v1/:issue_identifier` route so
  # that, e.g., `GET /api/v1/refresh` returns 405 rather than being
  # captured by the dynamic catchall and 404'd as `issue_not_found`.
  # They live outside the auth pipeline so wrong-method requests don't
  # leak a 401 instead of 405.
  scope "/", SymphonyElixirWeb do
    match(:*, "/api/v1/health", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/issues/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/events", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/events/stream", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/analytics", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/control/:command", ObservabilityApiController, :method_not_allowed)
    match(:*, "/", ObservabilityApiController, :method_not_allowed)
  end

  # Dynamic single-issue endpoint last so it doesn't capture
  # /api/v1/{issues,events,analytics,health,refresh,control}.
  scope "/", SymphonyElixirWeb do
    pipe_through(:control_auth)

    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
  end

  scope "/", SymphonyElixirWeb do
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
