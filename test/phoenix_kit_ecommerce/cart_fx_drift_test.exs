defmodule PhoenixKitEcommerce.CartFxDriftTest do
  @moduledoc "§4.4: drift of a cart's frozen rate against the live one, and the shopper's EXPLICIT reprice."
  use PhoenixKitEcommerce.DataCase, async: false
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop

  defp lang,
    do:
      PhoenixKitEcommerce.SlugResolver.normalize_language_public(
        PhoenixKitEcommerce.Translations.default_language()
      )

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)
    Repo.delete_all(PhoenixKitBilling.Currency)
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "5")

    {:ok, _} =
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

    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting #{n}", lang() => "Consulting #{n}"},
        "slug" => %{lang() => "drift-#{n}"},
        "price" => Decimal.new("138.00"),
        "compare_at_price" => Decimal.new("180.00"),
        "status" => "active",
        "currency" => "USD"
      })

    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "drift-#{n}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 2)
    Currency.put_request_currency(nil)
    %{eur: eur, cart: cart, product: product}
  end

  defp set_rate(eur, rate),
    do: {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: rate})

  test "no drift at or under the threshold, drift above it", %{cart: cart, eur: eur} do
    assert Shop.cart_rate_drift(cart) == nil
    set_rate(eur, "0.95")
    assert Shop.cart_rate_drift(cart) == nil
    set_rate(eur, "1.0")
    assert %{frozen: frozen, current: current, pct: pct} = Shop.cart_rate_drift(cart)
    assert Decimal.equal?(frozen, Decimal.new("0.909091"))
    assert Decimal.equal?(current, Decimal.new("1.0"))
    assert Decimal.equal?(pct, Decimal.new("10.00"))
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "15")
    assert Shop.cart_rate_drift(cart) == nil
  end

  test "a cart in the base currency, or without a frozen rate, never drifts", %{eur: eur} do
    {:ok, usd_cart} =
      Shop.create_cart(session_id: "drift-base-#{System.unique_integer([:positive])}")

    set_rate(eur, "2.0")
    assert Shop.cart_rate_drift(usd_cart) == nil
    assert Shop.cart_rate_drift(%{usd_cart | currency: "EUR", exchange_rate: nil}) == nil
  end

  test "a disabled cart currency is not reported as drift (§6.3 fail-safe must not leak in)", %{
    cart: cart,
    eur: eur
  } do
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{enabled: false})
    assert Shop.cart_rate_drift(cart) == nil
  end

  test "a non-numeric threshold falls back to 5" do
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "lots")
    assert Decimal.equal?(Shop.fx_rate_drift_alert_pct(), Decimal.new("5"))
  end

  test "a plain add never reprices a drifted cart (§4.4: no silent recalculation)", %{
    cart: cart,
    eur: eur,
    product: product
  } do
    set_rate(eur, "1.0")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    assert Enum.all?(cart.items, &Decimal.equal?(&1.unit_price, Decimal.new("125.45")))
  end

  test "refresh_cart_rate/1 re-snapshots every line at the new frozen rate and the totals follow",
       %{
         cart: cart,
         eur: eur
       } do
    set_rate(eur, "1.0")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("1.0"))
    [item] = cart.items
    assert Decimal.equal?(item.unit_price, Decimal.new("138.00"))
    assert Decimal.equal?(item.base_unit_price, Decimal.new("138.00"))
    assert Decimal.equal?(item.compare_at_price, Decimal.new("180.00"))
    assert Decimal.equal?(item.line_total, Decimal.new("276.00"))
    assert Decimal.equal?(cart.subtotal, Decimal.new("276.00"))
    assert Decimal.equal?(cart.total, Decimal.new("276.00"))
    assert Shop.cart_rate_drift(cart) == nil
  end

  test "refresh_cart_rate/1 refuses when a line has no base price or the currency is gone", %{
    cart: cart,
    eur: eur
  } do
    [item] = cart.items

    Repo.update_all(
      Ecto.Query.from(i in PhoenixKitEcommerce.CartItem, where: i.uuid == ^item.uuid),
      set: [base_unit_price: nil]
    )

    assert {:error, :no_base_price} = Shop.refresh_cart_rate(cart)
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{enabled: false})
    assert {:error, :currency_unavailable} = Shop.refresh_cart_rate(cart)
  end
end
