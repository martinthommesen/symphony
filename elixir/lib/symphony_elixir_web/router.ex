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

  scope "/", SymphonyElixirWeb do
    # Fixed observability/control routes are declared before the dynamic
    # `/api/v1/:issue_identifier` path so they take precedence. Ordering
    # here is significant: do not move `:issue_identifier` above any of
    # these.
    get("/api/v1/health", ObservabilityApiController, :health)
    match(:*, "/api/v1/health", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/state", ObservabilityApiController, :state)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/issues", ObservabilityApiController, :issues)
    match(:*, "/api/v1/issues", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/issues/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/issues/:issue_identifier", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/events", ObservabilityApiController, :events)
    match(:*, "/api/v1/events", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/events/stream", ObservabilityApiController, :event_stream)
    match(:*, "/api/v1/events/stream", ObservabilityApiController, :method_not_allowed)

    get("/api/v1/analytics", ObservabilityApiController, :analytics)
    match(:*, "/api/v1/analytics", ObservabilityApiController, :method_not_allowed)

    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)

    post("/api/v1/control/:command", ObservabilityApiController, :control)
    match(:*, "/api/v1/control/:command", ObservabilityApiController, :method_not_allowed)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)

    # Legacy/dynamic issue endpoint last so it doesn't capture
    # /api/v1/{issues,events,analytics,health,refresh,control}.
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)

    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
