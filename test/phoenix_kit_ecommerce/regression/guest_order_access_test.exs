defmodule PhoenixKitEcommerce.Regression.GuestOrderAccessTest do
  @moduledoc """
  Regression guard for guest access to their own order confirmation page.

  `/checkout/complete/:uuid` used to be readable by anyone holding the
  uuid, because `has_order_access?/2` returned true for any order whose
  owner was unconfirmed — and guest checkout creates exactly such users.
  Access is now proved by the shop session that PLACED the order, recorded
  as `order.metadata["session_id"]`.

  That fix introduced a worse bug than the one it closed, and this test
  exists because of it: `resolve_checkout_user/2` runs BEFORE
  `build_order_attrs/3` in the conversion chain, and for guest checkout it
  ends in `assign_cart_to_user/2`, which writes `session_id: nil` onto the
  cart. Reading `cart.session_id` at order-build time therefore yielded
  nil, every guest order was stamped with no placing session, and the
  guest was locked out of the page they were redirected to one line later.
  The cart column was nulled too, so even the `cart_uuid -> cart.session_id`
  fallback could not recover it.

  `convert_cart_to_order/2` now snapshots the session id before the chain
  runs. These tests drive the real public path end to end and MUST fail if
  that snapshot is removed.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop

  defp create_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Session Widget"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD"
      })

    product
  end

  defp create_shipping_method do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Standard",
        "price" => Decimal.new("0"),
        "active" => true
      })

    method
  end

  defp checkout_as_guest(session_id) do
    product = create_product()
    method = create_shipping_method()

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    {:ok, order} =
      Shop.convert_cart_to_order(cart,
        billing_data: %{
          "email" => "guest-#{System.unique_integer([:positive])}@example.com",
          "country" => "US"
        }
      )

    {cart, Billing.get_order_by_uuid(order.uuid)}
  end

  test "a guest order records the session that placed it" do
    session_id = "guest-session-#{System.unique_integer([:positive])}"

    {_cart, order} = checkout_as_guest(session_id)

    # The load-bearing assertion. Before the snapshot fix this was nil,
    # because assign_cart_to_user/2 had already cleared cart.session_id by
    # the time the order was built.
    assert order.metadata["session_id"] == session_id,
           """
           The order did not record the placing shop session.

           got: #{inspect(order.metadata["session_id"])}
           expected: #{inspect(session_id)}

           This is what lets a guest open their own confirmation page.
           If it is nil, `resolve_checkout_user/2` nulled `cart.session_id`
           before `build_order_attrs/3` read it — restore the snapshot taken
           at the top of `convert_cart_to_order/2`.
           """
  end

  test "guest checkout still assigns the cart to the created user" do
    # Guards the fix from the other side: the snapshot must not have been
    # achieved by skipping the user assignment that guest checkout needs.
    session_id = "guest-assign-#{System.unique_integer([:positive])}"

    {cart, order} = checkout_as_guest(session_id)

    reloaded = Shop.get_cart!(cart.uuid)

    refute is_nil(order.user_uuid), "guest checkout should create and attach a user"
    assert reloaded.user_uuid == order.user_uuid
    assert reloaded.status == "converted"
  end

  test "a logged-in checkout also records its session" do
    # The same nulling happens via resolve_logged_in_user_with_guest_cart/2
    # when a logged-in user checks out a cart that began as a guest cart.
    session_id = "member-session-#{System.unique_integer([:positive])}"

    {:ok, user} =
      Auth.register_user(%{
        email: "member-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    product = create_product()
    method = create_shipping_method()

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    {:ok, order} =
      Shop.convert_cart_to_order(cart,
        user_uuid: user.uuid,
        billing_data: %{"email" => user.email, "country" => "US"}
      )

    order = Billing.get_order_by_uuid(order.uuid)

    assert order.metadata["session_id"] == session_id
    assert order.user_uuid == user.uuid
  end

  test "cart_session_id/1 resolves the placing session for legacy orders" do
    # Orders created before metadata["session_id"] existed fall back to
    # metadata["cart_uuid"] -> cart.session_id. The cart row survives
    # conversion, so this stays resolvable for carts that were never
    # reassigned to a user.
    session_id = "legacy-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)

    assert Shop.cart_session_id(cart.uuid) == session_id
    assert Shop.session_has_cart?(session_id)

    refute Shop.session_has_cart?("no-such-session")
    assert Shop.cart_session_id("not-a-uuid") == nil
    assert Shop.cart_session_id(nil) == nil
  end
end
