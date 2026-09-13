defmodule PhoenixKitEcommerce.CartRebaseTest do
  @moduledoc """
  `PhoenixKitEcommerce.rebase_cart/1`: a cart that outlives a base-currency
  change is frozen against a base the shop no longer prices in.
  `reprice_for_base_change/3` leaves carts alone by design (§4.9 step 6),
  so the catch-up is lazy — add-to-cart, refresh, merge and conversion
  rebase first. Before this, `add_to_cart/4` stored a NEW-base
  `base_unit_price` into a cart frozen against the OLD base: unconverted
  for a cart in the old base, double-converted for any other currency.

  The base change is simulated the way a host does it — through
  `PhoenixKitBilling.change_base_currency/2` with this module's reprice
  callback — so the old base's row carries exactly the renormalized rate
  `rebase_cart/1` reads the multiplier back from.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.CartItem

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp product_attrs(extra) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "title" => %{"en" => "Vase #{n}", lang() => "Vase #{n}"},
        "slug" => %{lang() => "rebase-#{n}"},
        "price" => Decimal.new("138.00"),
        "compare_at_price" => Decimal.new("180.00"),
        "status" => "active",
        "currency" => "USD"
      },
      extra
    )
  end

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(Currency)

    {:ok, _usd} =
      Billing.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    {:ok, product} = Shop.create_product(product_attrs(%{}))
    %{product: product}
  end

  # USD -> EUR with the product catalog repriced, exactly as a host wires
  # it. Afterwards EUR reads 1.0 and USD reads the reciprocal (1.1).
  defp switch_base_to_eur! do
    assert {:ok, %{old_base: "USD"}} =
             Billing.change_base_currency("EUR",
               catalog_size: 1,
               reprice: &Shop.reprice_for_base_change/3
             )

    usd = Billing.get_currency_by_code("USD")
    assert Decimal.equal?(usd.exchange_rate, Decimal.new("1.100000"))
    assert %Currency{code: "EUR"} = Billing.get_base_currency()
  end

  defp cart_in(code) do
    Currency.put_request_currency(code)
    {:ok, cart} = Shop.create_cart(session_id: "rebase-#{System.unique_integer([:positive])}")
    Currency.put_request_currency(nil)
    cart
  end

  test "a cart in the old base is rebased: base amounts multiplied, frozen base and rate rewritten",
       %{product: product} do
    cart = cart_in("USD")
    {:ok, cart} = Shop.add_to_cart(cart, product, 2)
    assert %{currency: "USD", base_currency: "USD"} = cart

    switch_base_to_eur!()

    assert {:ok, rebased} = Shop.rebase_cart(cart)
    assert rebased.currency == "USD"
    assert rebased.base_currency == "EUR"
    # USD per EUR, from the renormalized table.
    assert Decimal.equal?(rebased.exchange_rate, Decimal.new("1.100000"))

    [item] = rebased.items
    # 138.00 USD x (1 / 1.1) = 125.45 EUR — the same figure the reprice
    # wrote onto the product itself.
    assert Decimal.equal?(item.base_unit_price, Decimal.new("125.45"))
    assert Decimal.equal?(Shop.get_product!(product.uuid).price, Decimal.new("125.45"))
    # The shopper's USD price is re-derived from the new base at the new
    # rate and lands back where it was, to the cent.
    assert_in_delta Decimal.to_float(item.unit_price), 138.00, 0.011
    assert_in_delta Decimal.to_float(item.compare_at_price), 180.00, 0.011
    assert item.currency == "USD"
    assert_in_delta Decimal.to_float(rebased.subtotal), 276.00, 0.021

    # Idempotent: a second call is a no-op on a current cart.
    assert {:ok, again} = Shop.rebase_cart(rebased)
    assert Decimal.equal?(hd(again.items).base_unit_price, Decimal.new("125.45"))
    assert Shop.cart_rate_drift(again) == nil
  end

  test "a cart in a foreign currency that BECOMES the base is not double-converted",
       %{product: product} do
    cart = cart_in("EUR")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    [item] = cart.items
    assert Decimal.equal?(item.unit_price, Decimal.new("125.45"))
    assert Decimal.equal?(item.base_unit_price, Decimal.new("138.00"))

    switch_base_to_eur!()

    assert {:ok, rebased} = Shop.rebase_cart(cart)
    assert %{currency: "EUR", base_currency: "EUR"} = rebased
    assert Decimal.equal?(rebased.exchange_rate, Decimal.new("1"))

    [item] = rebased.items
    assert Decimal.equal?(item.base_unit_price, Decimal.new("125.45"))
    # NOT 125.45 x 0.909091 = 114.05: the cart is in the base now, so the
    # line IS the base amount.
    assert Decimal.equal?(item.unit_price, Decimal.new("125.45"))
    assert Decimal.equal?(item.compare_at_price, Decimal.new("163.64"))
    assert Decimal.equal?(rebased.subtotal, Decimal.new("125.45"))
  end

  test "add_to_cart on a stale cart rebases first, so the new line's base price matches the old ones",
       %{product: product} do
    cart = cart_in("USD")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    switch_base_to_eur!()

    # The socket-held struct is still frozen against USD.
    assert cart.base_currency == "USD"
    # Created AFTER the switch: authored in EUR, the base now.
    {:ok, second} =
      Shop.create_product(product_attrs(%{"price" => Decimal.new("100.00"), "currency" => "EUR"}))

    assert {:ok, cart} = Shop.add_to_cart(cart, second, 1)
    assert cart.base_currency == "EUR"

    base_prices =
      cart.items |> Enum.map(& &1.base_unit_price) |> Enum.sort(&(Decimal.compare(&1, &2) != :gt))

    # Both lines in EUR: the rebased 138 USD line (125.45) and the new
    # 100 EUR line (100.00) — not 138.00 next to 100.00.
    assert Enum.map(base_prices, &Decimal.to_string/1) == ["100.00", "125.45"]

    new_line = Enum.find(cart.items, &(&1.product_uuid == second.uuid))
    # 100 EUR at 1.1 USD per EUR.
    assert Decimal.equal?(new_line.unit_price, Decimal.new("110.00"))
  end

  test "refresh_cart_rate/1 and cart_rate_drift/1 rebase first rather than mixing bases",
       %{product: product} do
    cart = cart_in("USD")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    switch_base_to_eur!()

    # A drift figure against the wrong base is meaningless: nothing to report.
    assert Shop.cart_rate_drift(cart) == nil

    assert {:ok, refreshed} = Shop.refresh_cart_rate(cart)
    assert refreshed.base_currency == "EUR"
    assert Decimal.equal?(refreshed.exchange_rate, Decimal.new("1.100000"))
    assert Decimal.equal?(hd(refreshed.items).base_unit_price, Decimal.new("125.45"))
  end

  test "conversion stamps the order with the current base" do
    {:ok, product} =
      Shop.create_product(
        product_attrs(%{"product_type" => "digital", "requires_shipping" => false})
      )

    cart = cart_in("USD")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    switch_base_to_eur!()

    n = System.unique_integer([:positive])

    assert {:ok, order} =
             Shop.convert_cart_to_order(cart,
               billing_data: %{
                 "email" => "rebase-#{n}@example.com",
                 "first_name" => "Test",
                 "last_name" => "Buyer",
                 "address_line1" => "1 Test Street",
                 "city" => "Testville",
                 "postal_code" => "10001",
                 "country" => "US"
               }
             )

    order = Billing.get_order_by_uuid(order.uuid)
    assert order.currency == "USD"
    assert order.base_currency == "EUR"
    assert Decimal.equal?(order.base_total, Decimal.new("125.45"))
  end

  test "a missing old-base row refuses rather than guessing the multiplier", %{product: product} do
    cart = cart_in("USD")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    switch_base_to_eur!()

    Repo.delete_all(from(c in Currency, where: c.code == "USD"))
    PhoenixKit.Cache.clear(:billing_currencies)

    assert {:error, :cart_base_unavailable} = Shop.rebase_cart(cart)
    assert {:error, :cart_base_unavailable} = Shop.add_to_cart(cart, product, 1)
    assert Shop.get_cart!(cart.uuid).base_currency == "USD"
  end

  test "a line without a base price rolls the whole rebase back", %{product: product} do
    cart = cart_in("USD")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    [item] = cart.items

    Repo.update_all(from(i in CartItem, where: i.uuid == ^item.uuid),
      set: [base_unit_price: nil]
    )

    switch_base_to_eur!()

    assert {:error, :no_base_price} = Shop.rebase_cart(cart)
    assert Shop.get_cart!(cart.uuid).base_currency == "USD"
  end

  test "a cart whose base is current, or a finished cart, is left alone", %{product: product} do
    cart = cart_in("EUR")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    assert {:ok, ^cart} = Shop.rebase_cart(cart)

    switch_base_to_eur!()
    converted = %{cart | status: "converted"}
    assert {:ok, ^converted} = Shop.rebase_cart(converted)
  end
end
