defmodule PhoenixKitEcommerce.Web.Plugs.ShopSession do
  @moduledoc """
  Plug that ensures a persistent shop session ID exists.

  This plug generates a unique session ID for guest users and stores it
  both in a dedicated cookie AND in the Phoenix session. This ensures
  the same cart is used across different pages.
  """

  import Plug.Conn

  alias PhoenixKitEcommerce, as: Shop

  @cookie_name "shop_session_id"
  # 30 days
  @cookie_max_age 60 * 60 * 24 * 30

  def init(opts), do: opts

  def call(conn, _opts) do
    if Shop.enabled?() do
      # First try to get from cookie (most reliable)
      # Then fall back to session
      session_id = get_shop_session_id(conn)

      case session_id do
        nil ->
          new_id = generate_session_id()

          conn
          |> put_resp_cookie(@cookie_name, new_id, cookie_opts(conn))
          |> put_session("shop_session_id", new_id)

        existing_id ->
          put_session(conn, "shop_session_id", existing_id)
      end
    else
      conn
    end
  end

  # This cookie is a cart identity, and since orders are now recognised by
  # the session that placed them (see `Policy.order_lookup_policy/0`) it is
  # also what proves "I am the guest who just checked out". It is therefore
  # signed: unsigned, a forged value picked up someone else's guest cart.
  #
  # `same_site: "Lax"` keeps it off cross-site requests, and `secure:` is
  # set whenever the request arrived over HTTPS — conditional rather than
  # hardcoded so plain-HTTP local development still gets a working cart.
  defp cookie_opts(conn) do
    [
      max_age: @cookie_max_age,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      sign: true
    ]
  end

  defp get_shop_session_id(conn) do
    # Try the signed cookie first, then the Phoenix session.
    #
    # A cookie that fails signature verification is IGNORED rather than
    # trusted — `fetch_cookies/2` simply omits it from `conn.cookies` — so
    # a tampered or pre-signing value falls through to the session, or to
    # minting a fresh id. Old unsigned cookies from before this change are
    # in that bucket: the visitor silently gets a new cart identity rather
    # than an error.
    conn = fetch_cookies(conn, signed: [@cookie_name])

    case conn.cookies[@cookie_name] do
      nil ->
        # Fall back to session
        get_session(conn, "shop_session_id")

      cookie_value ->
        cookie_value
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
