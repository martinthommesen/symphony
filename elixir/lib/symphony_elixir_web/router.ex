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
  # probes, and readiness checks work without a token. All other
  # observability endpoints — including the SSE stream — flow through
  # `:control_auth` below.
  scope "/", SymphonyElixirWeb do
    get("/api/v1/health", ObservabilityApiController, :health)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:control_auth)

    # Fixed observability/control routes are declared before the dynamic
    # `/api/v1/:issue_identifier` path so they take precedence. Ordering
    # here is significant: do not move `:issue_identifier` above any of
    # these.
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/issues", ObservabilityApiController, :issues)
    get("/api/v1/issues/:issue_identifier", ObservabilityApiController, :issue)
    get("/api/v1/events", ObservabilityApiController, :events)
    get("/api/v1/events/stream", ObservabilityApiController, :event_stream)
    get("/api/v1/analytics", ObservabilityApiController, :analytics)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    post("/api/v1/control/:command", ObservabilityApiController, :control)

    # Legacy/dynamic issue endpoint last so it doesn't capture
    # /api/v1/{issues,events,analytics,health,refresh,control}.
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
  end

  # Method-not-allowed fallbacks must remain outside the auth pipeline so
  # that, e.g., `GET /api/v1/refresh` reports 405 rather than 401. Phoenix
  # matches routes in declaration order, so the typed handlers above win
  # for the methods they accept; everything else falls through here.
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
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
