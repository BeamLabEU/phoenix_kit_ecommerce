defmodule PhoenixKitEcommerce.OrderFxFreezeTest do
  @moduledoc """
  `convert_cart_to_order/2` freezes currency/base/rate onto the order the
  same way `create_cart/1` freezes them onto the cart (spec §4.5, §2.4,
  §2.5, §4.2) - an order must not have its historical base/rate move
  under it the way a live currency-table lookup would. A product line
  also carries `base_unit_price` so an invoice/order-details page can
  show or re-derive the base figure without a fresh conversion against a
  rate that may have since moved (§12.2).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    %{eur: eur}
  end

  test "a EUR cart's order freezes currency/base/rate and carries base_unit_price on its line", %{
    eur: eur
  } do
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting", lang() => "Consulting"},
        "slug" => %{lang() => "order-fx-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    assert Decimal.equal?(cart.subtotal, Decimal.new("125.45"))

    billing = %{
      "email" => "order-fx-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }

    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: billing)

    assert order.currency == "EUR"
    assert order.base_currency == "USD"
    assert Decimal.equal?(order.exchange_rate, Decimal.new("0.909091"))

    # base_total = round(order.total / exchange_rate, 2) = round(125.45 /
    # 0.909091, 2) = 137.99, ONE CENT under the product's own 138.00 base
    # price - the round trip's own rounding (138.00 -> 125.45 -> 137.99),
    # not a bug: `total` is already the twice-rounded display figure by
    # the time this divides it back, same class of drift `taxable_base/3`
    # documents for multiply-then-divide. Recording the true result of the
    # spec's own formula rather than the number a naive inverse suggests.
    assert Decimal.equal?(order.base_total, Decimal.new("137.99"))

    [line] = order.line_items
    assert line["base_unit_price"] == "138.00"
    assert line["unit_price"] == "125.45"

    order_uuid = order.uuid

    # A later rate change must not move the ALREADY-CREATED order: it is
    # a historical record, not a live quote.
    {:ok, _} = Billing.update_currency(eur, %{exchange_rate: "0.5"})

    reloaded = Billing.get_order_by_uuid(order_uuid)
    assert reloaded.currency == "EUR"
    assert reloaded.base_currency == "USD"
    assert Decimal.equal?(reloaded.exchange_rate, Decimal.new("0.909091"))
    assert Decimal.equal?(reloaded.base_total, Decimal.new("137.99"))
    assert hd(reloaded.line_items)["base_unit_price"] == "138.00"
  end

  test "a shipping line carries no base_unit_price of its own" do
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Widget", lang() => "Widget"},
        "slug" => %{lang() => "order-fx-ship-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => true,
        "weight_grams" => 200
      })

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Flat#{System.unique_integer([:positive])}",
        "price" => Decimal.new("10.00"),
        "active" => true
      })

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    billing = %{
      "email" => "order-fx-ship-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }

    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: billing)

    shipping_line = Enum.find(order.line_items, &(&1["type"] == "shipping"))
    assert shipping_line["base_unit_price"] == nil
  end
end
