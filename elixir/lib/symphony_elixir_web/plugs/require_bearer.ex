defmodule SymphonyElixirWeb.Plugs.RequireBearer do
  @moduledoc """
  Plug that gates state-changing and observability endpoints behind the
  configured control token.

  Behavior:

  * If a token is configured, the request must carry a matching
    `Authorization: Bearer <token>` header. Otherwise the request is
    rejected with 401.
  * If no token is configured (read-only mode), the request is permitted
    only when the server is bound to a loopback address. Non-loopback
    binds without a token return 403 to prevent silent network exposure
    of operational data.

  The response envelope mirrors the route family: paths under
  `/api/v1/control/*` use the `{ok: false, error: {...}}` cockpit shape;
  legacy paths use the original `{error: {...}}` shape so existing
  wrapper scripts continue to parse error bodies.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Plug.Conn
  alias SymphonyElixir.Observability.Control

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case authenticate(conn) do
      :ok -> conn
      :allow -> conn
      {:reject, status, code, message} -> reject(conn, status, code, message)
    end
  end

  defp authenticate(conn) do
    header =
      case get_req_header(conn, "authorization") do
        [value | _] -> value
        _ -> nil
      end

    presented = Control.extract_bearer(header)

    case Control.authenticate(presented) do
      :ok ->
        :ok

      :read_only ->
        # No token configured. Permit only when bound to a loopback
        # interface; otherwise the read endpoints would leak operational
        # data over the network without authentication. The plug now
        # gates both reads (state/issues/events/analytics) and writes
        # (control/refresh) so the message is route-agnostic.
        if Control.loopback_only?() do
          :allow
        else
          {:reject, 403, "control_disabled", "Observability and control endpoints are disabled (no token configured) and the server is not bound to a loopback address."}
        end

      {:error, :missing_token} ->
        {:reject, 401, "missing_token", "Authorization: Bearer <token> required"}

      {:error, :invalid_token} ->
        {:reject, 401, "invalid_token", "Invalid bearer token"}
    end
  end

  defp reject(conn, status, code, message) do
    body =
      if control_envelope?(conn) do
        %{ok: false, error: %{code: code, message: message}}
      else
        %{error: %{code: code, message: message}}
      end

    conn
    |> put_status(status)
    |> json(body)
    |> halt()
  end

  defp control_envelope?(%Conn{path_info: ["api", "v1", "control" | _]}), do: true
  defp control_envelope?(_), do: false
end
