defmodule PhoenixKitEcommerce.CartHandoff do
  @moduledoc false
  # What `PhoenixKitEcommerce.handoff_snapshot/1` and `handoff_apply/2` do; see
  # their docs. Core's `PhoenixKit.Handoff` reaches them through
  # `function_exported?/3` with plain maps and no core types; the same maps
  # are accepted that a caller of this module would build by hand.
  #
  # The cart uuid in a payload is a bearer secret that travelled through a
  # redirect, so the cart it names is adopted only if it is a live GUEST cart
  # (`guest_source/1`, and again under the row lock by
  # `PhoenixKitEcommerce.move_cart_lines/3`). Nothing here trusts the payload
  # beyond that, and nothing here raises: the caller is a redirect endpoint.

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import Ecto.Query, warn: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartMove
  alias PhoenixKitEcommerce.Web.Plugs.ShopSession

  require Logger

  @nothing %{moved: 0, skipped: []}

  # --- snapshot ----------------------------------------------------------------

  def snapshot(context) do
    with {:ok, nil} <- user_uuid(context),
         session_id when is_binary(session_id) <- shop_session_id(context),
         %Cart{uuid: uuid, items: [_ | _]} <- Shop.find_active_cart(session_id: session_id) do
      %{"cart_uuid" => uuid}
    else
      _nothing_to_carry -> nil
    end
  rescue
    error -> failed(:handoff_snapshot, error, nil)
  catch
    :exit, _reason -> nil
  end

  # --- apply -------------------------------------------------------------------

  def apply_payload(context, payload) do
    case identity(context) do
      {:ok, identity} ->
        case guest_source(payload) do
          %Cart{} = source -> apply_for(identity, source)
          nil -> follow_currency(identity)
        end

      :error ->
        {:ok, @nothing}
    end
  rescue
    error -> failed(:handoff_apply, error, {:ok, @nothing})
  catch
    :exit, _reason -> {:ok, @nothing}
  end

  # Nothing to carry. A signed-in shopper's own cart is found by user on every
  # domain, so it only has to be in this domain's currency (when the request
  # names one); a guest has nothing here to look after.
  defp follow_currency(%{user_uuid: user_uuid, currency: currency} = identity)
       when is_binary(user_uuid) and is_binary(currency) do
    with %Cart{} = cart <-
           Shop.find_active_cart(user_uuid: user_uuid, session_id: identity.session_id) do
      _ = Shop.redenominate_cart(cart, currency)
    end

    {:ok, @nothing}
  end

  defp follow_currency(_identity), do: {:ok, @nothing}

  # A signed-in shopper's cart is found by user on every domain; a guest
  # arriving for the first time has no session here and is given one.
  defp apply_for(identity, source) do
    with :ok <- usable_currency(identity.currency),
         {:ok, session_id, cookies} <- target_session(identity),
         {:ok, target} <- target_cart(identity, session_id),
         {:ok, target} <- into_currency(target, identity.currency),
         {:ok, _target, report} <-
           Shop.move_cart_lines(source, target,
             language: identity.language,
             # `:assistant`: the shopper added nothing on this domain, so no
             # "item added" notification per line.
             via: :assistant,
             # Judged again on the locked row: the unlocked read above may be
             # many events old.
             guest_source: true,
             # A line that cannot be moved is not lost: it stays in the source.
             keep_skipped: true
           ) do
      {:ok, finish(report, cookies_for(report, cookies), identity.locale)}
    else
      # Lost a race with whoever else ended one of the carts, or the payload
      # named the target's own cart: nothing left to carry.
      {:error, reason}
      when reason in [
             :cart_not_active,
             :same_cart,
             :cart_not_found,
             :not_a_guest_cart,
             :cart_empty
           ] ->
        {:ok, @nothing}

      # The source is eligible but cannot be carried right now: it stays where
      # it is, with every line, and the shopper is told so.
      {:error, reason} ->
        refused(source, refusal_reason(reason), identity.locale)
    end
  end

  defp refusal_reason(reason) when is_atom(reason), do: reason
  defp refusal_reason(_changeset_or_other), do: :cart_unavailable

  defp refused(source, reason, locale) do
    report = %{moved: 0, skipped: CartMove.skipped_lines(source, reason)}
    {:ok, finish(report, [], locale)}
  end

  # Only a currency the shop prices in is moved into; checked before anything is
  # created, so a refusal leaves no stray cart. No currency means the cart is
  # taken as it is: the cart page brings it into the domain's on its next mount.
  defp usable_currency(nil), do: :ok

  defp usable_currency(code),
    do: if(Shop.pricing_currency?(code), do: :ok, else: {:error, :currency_unavailable})

  defp into_currency(target, nil), do: {:ok, target}
  defp into_currency(target, code), do: Shop.redenominate_cart(target, code)

  # The shopper's cart on this domain is looked up, or created, under the
  # identity lock.
  defp target_cart(%{user_uuid: user_uuid}, session_id),
    do: Shop.get_or_create_cart(user_uuid: user_uuid, session_id: session_id)

  # The identity the moved lines land under. A visitor who already has a shop
  # session here keeps it. One who has none (a first visit: nothing of this
  # module's is in the session or in a verified cookie) is given a fresh id,
  # minted and set exactly as `Web.Plugs.ShopSession` does, so the next request
  # of that browser finds the cart. A signed-in shopper's cart is found by user.
  defp target_session(%{session_id: session_id}) when is_binary(session_id),
    do: {:ok, session_id, []}

  defp target_session(%{user_uuid: user_uuid}) when is_binary(user_uuid),
    do: {:ok, nil, []}

  defp target_session(_identity) do
    session_id = ShopSession.generate_session_id()
    cookie = {ShopSession.cookie_name(), session_id, ShopSession.cookie_options(true)}
    {:ok, session_id, [cookie]}
  end

  # A cookie for an id nothing was moved into is of no use to the browser.
  defp cookies_for(%{moved: moved}, cookies) when moved > 0, do: cookies
  defp cookies_for(_report, _cookies), do: []

  # The cart a payload names, if and only if it is a live guest cart.
  defp guest_source(payload) do
    with uuid when is_binary(uuid) <- payload_cart_uuid(payload),
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Cart{} = cart <- Shop.get_cart(uuid),
         true <- guest_cart?(cart) do
      cart
    else
      _not_adoptable -> nil
    end
  end

  defp payload_cart_uuid(%{"cart_uuid" => uuid}), do: uuid
  defp payload_cart_uuid(%{cart_uuid: uuid}), do: uuid
  defp payload_cart_uuid(_payload), do: nil

  # Active, owned by nobody, not an API cart (those have their own claim), and
  # worth carrying.
  defp guest_cart?(%Cart{status: "active", user_uuid: nil, session_id: session_id, items: items}),
    do: is_binary(session_id) and not api_session?(session_id) and items != []

  defp guest_cart?(_cart), do: false

  # --- the context ---------------------------------------------------------------

  # `session_id` is nil when the visitor has none yet; the currency is the one
  # the caller names, else the request's display currency when the request
  # names one the shop prices in, else none (the target cart keeps its own).
  defp identity(context) when is_map(context) do
    with {:ok, user_uuid} <- user_uuid(context) do
      {:ok,
       %{
         user_uuid: user_uuid,
         session_id: shop_session_id(context),
         currency: present(fetch(context, :currency)) || Shop.request_display_currency_code(),
         language: present(fetch(context, :language)) || present(fetch(context, :locale)),
         locale: present(fetch(context, :locale))
       }}
    end
  end

  defp identity(_context), do: :error

  # `{:ok, nil}` for a visitor, `{:ok, uuid}` for an account, `:error` for
  # anything that is not a uuid: a malformed one is no identity, and no query.
  defp user_uuid(context) when is_map(context) do
    case fetch(context, :user_uuid) do
      value when value in [nil, ""] -> {:ok, nil}
      value when is_binary(value) -> cast_uuid(value)
      _other -> :error
    end
  end

  defp user_uuid(_context), do: :error

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  # The visitor's shop session id: what the caller names outright, else the
  # SIGNED cookie (verified, the way the plug verifies it), else the Phoenix
  # session (the plug mirrors the id into it). Never an unsigned cookie value,
  # and never an `api:` session, which is a cart token and not a browser.
  defp shop_session_id(context) do
    [
      present(fetch(context, :shop_session_id)),
      context |> fetch(:cookies) |> ShopSession.signed_cookie_id() |> present(),
      context |> fetch(:session) |> fetch(:shop_session_id) |> present()
    ]
    |> Enum.find(&(is_binary(&1) and not api_session?(&1)))
  end

  defp api_session?(session_id), do: String.starts_with?(session_id, "api:")

  # Keys as atoms or as strings: a core that carries the context through JSON
  # gets strings back, and the session of a request has string keys.
  defp fetch(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp fetch(_other, _key), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # Nothing may raise, but what raised is worth knowing: the kind only, never a
  # message (those can carry what the hook was handed).
  defp failed(hook, error, answer) do
    Logger.error("[Shop] #{hook} failed: #{inspect(error.__struct__)}")
    answer
  end

  # --- what the shopper is told ------------------------------------------------

  # The report, plus what core shows and sets: `notices` (translated lines for
  # the flash) and `cookies` (`{name, value, opts}`), each only when there is
  # something to say.
  defp finish(report, cookies, locale) do
    report
    |> put_unless_empty(:notices, notices(report, locale))
    |> put_unless_empty(:cookies, cookies)
  end

  defp put_unless_empty(report, _key, []), do: report
  defp put_unless_empty(report, key, value), do: Map.put(report, key, value)

  defp notices(%{moved: moved, skipped: skipped}, locale) do
    in_locale(locale, fn ->
      Enum.reject([moved_notice(moved), skipped_notice(skipped)], &is_nil/1)
    end)
  end

  defp moved_notice(0), do: nil

  defp moved_notice(count) do
    ngettext(
      "Your cart came with you: %{count} item.",
      "Your cart came with you: %{count} items.",
      count
    )
  end

  defp skipped_notice([]), do: nil

  defp skipped_notice(skipped) do
    shown = skipped |> Enum.take(3) |> Enum.map_join(", ", &skipped_product/1)
    more = if length(skipped) > 3, do: " …", else: ""

    gettext("These stayed in your cart on the other site: %{products}.",
      products: shown <> more
    )
  end

  defp skipped_product(%{name: name, reason: reason}) do
    gettext("%{name} (%{reason})",
      name: present(name) || gettext("an item"),
      reason: reason_text(reason)
    )
  end

  defp reason_text(reason) when reason in [:not_found, :not_on_sale, :invalid_options],
    do: gettext("no longer available")

  defp reason_text(:insufficient_stock), do: gettext("not enough in stock")
  defp reason_text(:quantity_cap), do: gettext("quantity limit reached")
  defp reason_text(_other), do: gettext("cannot be added here right now")

  # The module's catalogues are plain codes ("de") and the locale core hands
  # over is an enabled language code that may be a dialect ("de-DE"): the
  # catalogue is picked the way `Web.Helpers.put_content_locale/1` picks it,
  # but only for this call: the process locale of the request is left alone.
  defp in_locale(locale, fun) when is_binary(locale) do
    known = Gettext.known_locales(PhoenixKitEcommerce.Gettext)
    base = locale |> String.split(~r/[-_]/) |> List.first()

    case Enum.find([locale, base], &(&1 in known)) do
      nil -> fun.()
      found -> Gettext.with_locale(PhoenixKitEcommerce.Gettext, found, fun)
    end
  end

  defp in_locale(_locale, fun), do: fun.()
end
