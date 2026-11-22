defmodule PhoenixKitEcommerce.CartHandoff do
  @moduledoc false
  # What `PhoenixKitEcommerce.handoff_snapshot/1` and `handoff_apply/2` do; see
  # their docs. Plain maps in and out, no core types: core reaches them through
  # `function_exported?/3`.
  #
  # The cart uuid in a payload is a bearer secret that travelled through a
  # redirect, so the cart it names is adopted only if it is a live GUEST cart
  # (`guest_cart?/1`). Nothing here trusts the payload beyond that.

  import Ecto.Query, warn: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.Cart

  @nothing %{moved: 0, skipped: []}

  # --- snapshot ----------------------------------------------------------------

  def snapshot(context) when is_map(context) do
    with nil <- present(fetch(context, :user_uuid)),
         session_id when is_binary(session_id) <- present(fetch(context, :shop_session_id)),
         false <- api_session?(session_id),
         %Cart{uuid: uuid, items: [_ | _]} <- Shop.find_active_cart(session_id: session_id) do
      %{"cart_uuid" => uuid}
    else
      _nothing_to_carry -> nil
    end
  end

  def snapshot(_context), do: nil

  # --- apply -------------------------------------------------------------------

  def apply_payload(context, payload) when is_map(context) do
    case identity(context) do
      {:ok, identity} -> apply_for(identity, guest_source(payload))
      :error -> {:error, :invalid_context}
    end
  rescue
    error ->
      if CartWriter.deadlock?(error), do: {:error, :busy}, else: reraise(error, __STACKTRACE__)
  end

  def apply_payload(_context, _payload), do: {:error, :invalid_context}

  # Nothing to carry. A signed-in shopper's own cart is found by user on every
  # domain, so it only has to be in this domain's currency; a guest has nothing
  # here to look after.
  defp apply_for(%{user_uuid: nil}, nil), do: {:ok, @nothing}

  defp apply_for(%{user_uuid: user_uuid} = identity, nil) do
    case Shop.find_active_cart(user_uuid: user_uuid, session_id: identity.session_id) do
      nil -> {:ok, @nothing}
      cart -> cart |> Shop.redenominate_cart(identity.currency) |> nothing_moved()
    end
  end

  defp apply_for(identity, %Cart{} = source) do
    with {:ok, target} <- target_cart(identity),
         {:ok, target} <- Shop.redenominate_cart(target, identity.currency),
         # `:assistant`: the shopper added nothing on this domain, so no
         # "item added" notification per line.
         {:ok, _target, report} <-
           Shop.move_cart_lines(source, target, language: identity.language, via: :assistant) do
      {:ok, report}
    else
      # Lost a race with whoever else ended one of the carts, or the payload
      # named the target's own cart: nothing left to carry.
      {:error, reason} when reason in [:cart_not_active, :same_cart, :cart_not_found] ->
        {:ok, @nothing}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, _changeset} ->
        {:error, :cart_unavailable}
    end
  end

  defp nothing_moved({:ok, _cart}), do: {:ok, @nothing}
  defp nothing_moved({:error, :cart_not_active}), do: {:ok, @nothing}
  defp nothing_moved({:error, reason}), do: {:error, reason}

  # The shopper's cart on this domain: by user when signed in, else by the
  # session of this domain. Creation takes the identity lock.
  defp target_cart(%{user_uuid: user_uuid, session_id: session_id}),
    do: Shop.get_or_create_cart(user_uuid: user_uuid, session_id: session_id)

  # The cart a payload names, if and only if it is a live guest cart.
  defp guest_source(payload) do
    with uuid when is_binary(uuid) <- payload_cart_uuid(payload),
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

  defp identity(context) do
    user_uuid = present(fetch(context, :user_uuid))
    session_id = present(fetch(context, :shop_session_id))

    if user_uuid || session_id do
      {:ok,
       %{
         user_uuid: user_uuid,
         session_id: session_id,
         currency: present(fetch(context, :currency)) || Shop.get_display_currency_code(),
         language: present(fetch(context, :language))
       }}
    else
      :error
    end
  end

  defp api_session?(session_id), do: String.starts_with?(session_id, "api:")

  # Keys as atoms or as strings: a core that carries the context through JSON
  # gets strings back.
  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
end
