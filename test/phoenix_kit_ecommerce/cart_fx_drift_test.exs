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

  # Returns the UPDATED struct — a caller that reprices twice must thread
  # it through rather than reusing the original: `update_currency/2`'s
  # changeset diffs the new value against the struct it is CALLED with,
  # not against the database, so calling it twice with the same stale
  # struct and a value that happens to equal that struct's original
  # field produces an empty changeset (no perceived change) and silently
  # writes nothing on the second call.
  defp set_rate(eur, rate) do
    {:ok, updated} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: rate})
    updated
  end

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

  # §4.3.1 known rounding bound: `compare_at_price` has no `base_compare_at_price`
  # column to re-derive from exactly the way `unit_price` re-derives from
  # `base_unit_price` (a new column means a migration, deliberately
  # deferred — the owner's call, not worth it for a crossed-out price).
  # Each reprice therefore inverts it through `to_base/2`'s 2-decimal
  # rounding before reconverting, so REPEATED reprices can drift the
  # displayed "was" price by a cent or two against a fresh conversion.
  # `unit_price` never has this error - it always re-derives exactly.
  # This pins the ACTUAL observed numbers for two consecutive reprices
  # on the same cart (0.909091 -> 1.0 -> 0.909091 again) rather than
  # asserting a drift that may or may not occur for a given pair of
  # rates - `unit_price` must land back on 125.45 exactly, and
  # `compare_at_price` is asserted only to be within the documented
  # 0.02 bound of its original 163.64, not to a specific drifted value.
  test "two consecutive reprices: unit_price is exact, compare_at_price is bounded within a cent",
       %{cart: cart, eur: eur} do
    original_compare_at = List.first(cart.items).compare_at_price

    eur = set_rate(eur, "1.0")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)

    _eur = set_rate(eur, "0.909091")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)

    [item] = cart.items
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    assert Decimal.equal?(item.unit_price, Decimal.new("125.45"))

    drift =
      item.compare_at_price
      |> Decimal.sub(original_compare_at)
      |> Decimal.abs()

    assert Decimal.compare(drift, Decimal.new("0.02")) != :gt,
           "compare_at_price drifted #{drift} away from #{original_compare_at} " <>
             "(now #{item.compare_at_price}) - past the documented 0.02 bound"
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
