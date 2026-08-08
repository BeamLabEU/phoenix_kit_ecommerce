defmodule PhoenixKitEcommerce.ConvertSkipShippingTest do
  @moduledoc """
  `shop_shipping_skip_mode` at conversion time: whether `convert_cart_to_order/2`
  may create an order for a physical cart that never got a shipping method.

  `:off` keeps the long-standing hard requirement (see
  `Regression.PurchaseGuardsTest`). `:always` skips unconditionally. `:fallback`
  only skips when no active method covers the checkout country - a country a
  method DOES cover stays a hard requirement, same as `:off`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  setup [:cart_ready_for_checkout_without_shipping]

  test "mode off (default) still rejects", %{cart: cart, opts: opts} do
    assert {:error, :no_shipping_method} = Shop.convert_cart_to_order(cart, opts)
  end

  test "mode always converts and stamps metadata", %{cart: cart, opts: opts} do
    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")

    assert {:ok, order} = Shop.convert_cart_to_order(cart, opts)
    assert order.metadata["shipping_skipped"] == true
    assert order.metadata["shipping_skip_reason"] == "always"
    refute Enum.any?(order.line_items, &(&1["type"] == "shipping"))
  end

  test "mode fallback converts only when no method covers the country", %{cart: cart} do
    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "fallback", "shop")

    # The fixture's active method only covers "EE" - "US" is not served by
    # anything, so fallback must let this one through.
    opts = [billing_data: complete_billing("US")]

    assert {:ok, order} = Shop.convert_cart_to_order(cart, opts)
    assert order.metadata["shipping_skipped"] == true
    assert order.metadata["shipping_skip_reason"] == "no_method_for_country"
    refute Enum.any?(order.line_items, &(&1["type"] == "shipping"))
  end

  test "mode fallback still rejects when methods exist for the country", %{cart: cart} do
    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "fallback", "shop")

    # "EE" IS covered by the fixture's method - fallback must not skip it.
    opts = [billing_data: complete_billing("EE")]

    assert {:error, :no_shipping_method} = Shop.convert_cart_to_order(cart, opts)
  end

  # A physical cart, WITHOUT a shipping method selected, ready for
  # `convert_cart_to_order/2` - plus one active shipping method restricted
  # to "EE" only, so tests can choose a covered ("EE") or uncovered ("US")
  # checkout country via `opts`.
  defp cart_ready_for_checkout_without_shipping(_context) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Skip-Shipping Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, _method} =
      Shop.create_shipping_method(%{
        "name" => "Estonia Only",
        "price" => Decimal.new("5.00"),
        "active" => true,
        "countries" => ["EE"]
      })

    {:ok, cart} =
      Shop.create_cart(session_id: "skip-shipping-#{System.unique_integer([:positive])}")

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    %{cart: cart, opts: [billing_data: complete_billing("EE")]}
  end

  defp complete_billing(country) do
    %{
      "email" => "skip-shipping-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => country
    }
  end
end
