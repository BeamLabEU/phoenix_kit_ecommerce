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
      case get_shop_session_id(conn) do
        {:signed, existing_id} ->
          put_session(conn, "shop_session_id", existing_id)

        {:legacy, existing_id} ->
          # Adopted from a pre-signing cookie: re-issue it signed so this
          # visitor migrates once and never takes the legacy path again.
          conn
          |> put_resp_cookie(@cookie_name, existing_id, cookie_opts(conn))
          |> put_session("shop_session_id", existing_id)

        nil ->
          new_id = generate_session_id()

          conn
          |> put_resp_cookie(@cookie_name, new_id, cookie_opts(conn))
          |> put_session("shop_session_id", new_id)
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

  # Resolution order: signed cookie, Phoenix session, then the one-time
  # legacy-cookie migration.
  #
  # Returns `{:signed, id}` for a trusted value, `{:legacy, id}` for one
  # adopted from a pre-signing cookie (the caller re-issues it signed), or
  # nil to mint a fresh identity.
  defp get_shop_session_id(conn) do
    signed_conn = fetch_cookies(conn, signed: [@cookie_name])

    cond do
      value = signed_conn.cookies[@cookie_name] ->
        {:signed, value}

      value = get_session(conn, "shop_session_id") ->
        {:signed, value}

      true ->
        adopt_legacy_cookie(conn)
    end
  end

  # Migration for cookies written before this one was signed.
  #
  # `fetch_cookies/2` silently DROPS a value that fails verification, so
  # without this every existing guest would lose their in-progress cart the
  # moment the shop upgraded — a real break for every deployed store, not a
  # theoretical one.
  #
  # The adoption is deliberately narrow: an unsigned value is accepted only
  # when it actually names a cart that exists. That keeps the migration
  # self-limiting and makes forgery pointless — this cookie now also proves
  # guest ORDER ownership, so blindly trusting any unsigned string would
  # hand an attacker exactly the capability the signing was added to
  # protect. A guessed value matches no cart and is refused; a real
  # session_id is 32 bytes of crypto-random, so guessing one is not a
  # threat model, it is a wish. Legacy visitors with a cookie but no cart
  # lose nothing by being issued a fresh id.
  #
  # The path also disappears on its own: every legacy visitor is upgraded
  # on their next request, so it stops being reached once carts age out.
  defp adopt_legacy_cookie(conn) do
    conn = fetch_cookies(conn)

    with raw when is_binary(raw) <- conn.cookies[@cookie_name],
         true <- plausible_session_id?(raw),
         true <- Shop.session_has_cart?(raw) do
      {:legacy, raw}
    else
      _ -> nil
    end
  end

  # Shape check before touching the database, so junk cookies cost nothing.
  # `generate_session_id/0` emits 32 random bytes as unpadded base64url.
  defp plausible_session_id?(value) do
    byte_size(value) == 43 and value =~ ~r/^[A-Za-z0-9_-]+$/
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
