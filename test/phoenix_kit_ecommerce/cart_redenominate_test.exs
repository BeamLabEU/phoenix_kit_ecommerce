defmodule PhoenixKitEcommerce.CartRedenominateTest do
  @moduledoc """
  `PhoenixKitEcommerce.redenominate_cart/2`: an ACTIVE cart is brought into
  another display currency, because a cart is paid in the currency of the site
  it is paid on. The cart's currency and frozen rate are rewritten at the
  CURRENT rate and every line is re-derived from its exact `base_unit_price`
  through the same snapshot an add-to-cart uses, so a re-denominated line is
  indistinguishable from one added fresh at that rate.

  Rounding: `unit_price`, line totals and the subtotal come from
  `base_unit_price` and are exact however often the cart changes currency.
  `compare_at_price` has no base column and is inverted through the cart's
  own 2-decimal conversion, so a round trip can move the crossed-out price by
  up to a cent (a half cent of rounding on the foreign leg, divided by a rate
  between 0.5 and 2, rounded to a cent): pinned below at 9.99 -> 9.98.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp product!(extra \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          "title" => %{"en" => "Vase #{n}", lang() => "Vase #{n}"},
          "slug" => %{lang() => "redenominate-#{n}"},
          "price" => Decimal.new("138.00"),
          "compare_at_price" => Decimal.new("180.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "physical",
          "requires_shipping" => true,
          "weight_grams" => 300
        },
        extra
      )

    {:ok, product} = Shop.create_product(attrs)
    product
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

    {:ok, eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    %{eur: eur}
  end

  defp cart_in(code) do
    Currency.put_request_currency(code)

    {:ok, cart} =
      Shop.create_cart(session_id: "redenominate-#{System.unique_integer([:positive])}")

    Currency.put_request_currency(nil)
    cart
  end

  defp usd_cart_with(product, quantity) do
    {:ok, cart} = Shop.add_to_cart(cart_in("USD"), product, quantity)
    cart
  end

  # What is stored for the cart: the row and its lines, as the database holds
  # them. Equal before and after means nothing was written.
  defp stored(cart_uuid) do
    {Repo.get!(Cart, cart_uuid),
     Repo.all(from(i in CartItem, where: i.cart_uuid == ^cart_uuid, order_by: i.uuid))}
  end

  defp dec(value), do: Decimal.new(value)

  defp assert_total_identity(cart) do
    expected =
      cart.subtotal
      |> Decimal.add(cart.shipping_amount)
      |> Decimal.add(cart.tax_amount)
      |> Decimal.sub(cart.discount_amount || dec("0"))

    assert Decimal.equal?(cart.total, expected)
  end

  describe "USD -> EUR" do
    test "rewrites currency and frozen rate and re-snapshots every line from its base price" do
      cart = usd_cart_with(product!(), 2)
      assert %{currency: "USD", base_currency: "USD"} = cart

      assert {:ok, eur} = Shop.redenominate_cart(cart, "EUR")

      assert %{currency: "EUR", base_currency: "USD"} = eur
      assert Decimal.equal?(eur.exchange_rate, dec("0.909091"))
      [line] = eur.items
      assert line.currency == "EUR"
      # 138.00 x 0.909091 = 125.454558 -> 125.45; 180.00 x 0.909091 = 163.64
      assert Decimal.equal?(line.unit_price, dec("125.45"))
      assert Decimal.equal?(line.base_unit_price, dec("138.00"))
      assert Decimal.equal?(line.compare_at_price, dec("163.64"))
      assert Decimal.equal?(line.line_total, dec("250.90"))
      assert Decimal.equal?(eur.subtotal, dec("250.90"))
      assert_total_identity(eur)

      # What was returned is what was stored.
      {row, [stored_line]} = stored(cart.uuid)
      assert row.currency == "EUR"
      assert Decimal.equal?(row.subtotal, dec("250.90"))
      assert Decimal.equal?(stored_line.unit_price, dec("125.45"))
      assert stored_line.currency == "EUR"
    end

    test "a line comes out exactly as an add-to-cart in EUR would have priced it" do
      product = product!()
      converted = Shop.redenominate_cart(usd_cart_with(product, 1), "EUR") |> elem(1)

      Currency.put_request_currency("EUR")

      {:ok, fresh} =
        Shop.add_to_cart(Shop.create_cart(session_id: "fresh-eur") |> elem(1), product, 1)

      Currency.put_request_currency(nil)

      [a] = converted.items
      [b] = fresh.items

      for field <- [:unit_price, :base_unit_price, :compare_at_price, :line_total, :currency] do
        assert Map.fetch!(a, field) == Map.fetch!(b, field), "#{field} differs"
      end

      assert converted.subtotal == fresh.subtotal
    end

    test "uses the CURRENT rate, not the one the cart was frozen under", %{eur: eur} do
      cart = usd_cart_with(product!(), 1)
      {:ok, _} = Billing.update_currency(eur, %{exchange_rate: "0.95"})

      assert {:ok, converted} = Shop.redenominate_cart(cart, "EUR")

      assert Decimal.equal?(converted.exchange_rate, dec("0.95"))
      assert Decimal.equal?(hd(converted.items).unit_price, dec("131.10"))
    end

    test "the shipping charge is recalculated in the new currency" do
      cart = usd_cart_with(product!(), 1)

      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Flat #{System.unique_integer([:positive])}",
          "price" => dec("10.00"),
          "active" => true
        })

      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
      assert Decimal.equal?(cart.shipping_amount, dec("10.00"))

      assert {:ok, eur} = Shop.redenominate_cart(cart, "EUR")

      assert Decimal.equal?(eur.shipping_amount, dec("9.09"))
      assert Decimal.equal?(eur.total, dec("134.54"))
      assert_total_identity(eur)
      assert {:ok, usd} = Shop.redenominate_cart(eur, "USD")
      assert Decimal.equal?(usd.shipping_amount, dec("10.00"))
      assert Decimal.equal?(usd.total, dec("148.00"))
      assert_total_identity(usd)
    end

    test "a stored discount is carried across the currency, not relabelled" do
      cart = usd_cart_with(product!(), 1)

      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid),
        set: [discount_amount: dec("5.00")]
      )

      cart = Shop.get_cart(cart.uuid)

      assert {:ok, eur} = Shop.redenominate_cart(cart, "EUR")
      assert Decimal.equal?(eur.discount_amount, dec("4.55"))
      assert_total_identity(eur)

      assert {:ok, usd} = Shop.redenominate_cart(eur, "USD")
      assert Decimal.equal?(usd.discount_amount, dec("5.00"))
      assert_total_identity(usd)
    end

    test "an empty cart changes currency too, whatever the request currency says" do
      cart = cart_in("USD")
      assert cart.items == []

      # The emptied-cart refresh follows the REQUEST currency; here the
      # request says EUR while the caller asks for USD -> EUR -> USD.
      Currency.put_request_currency("EUR")
      assert {:ok, eur} = Shop.redenominate_cart(cart, "EUR")
      assert eur.currency == "EUR"
      assert Decimal.equal?(eur.exchange_rate, dec("0.909091"))

      Currency.put_request_currency("EUR")
      assert {:ok, usd} = Shop.redenominate_cart(eur, "USD")
      assert usd.currency == "USD"
      assert usd.base_currency == "USD"
      assert Decimal.equal?(usd.exchange_rate, dec("1"))
      assert Repo.get!(Cart, cart.uuid).currency == "USD"
    end

    test "a cart frozen against an earlier base is rebased first" do
      cart = usd_cart_with(product!(), 1)

      assert {:ok, %{old_base: "USD"}} =
               Billing.change_base_currency("EUR",
                 catalog_size: 1,
                 reprice: &Shop.reprice_for_base_change/3
               )

      # The cart is still USD against base USD; the shop is now based in EUR.
      assert {:ok, eur} = Shop.redenominate_cart(cart, "EUR")

      assert %{currency: "EUR", base_currency: "EUR"} = eur
      [line] = eur.items
      # 138.00 USD / 1.1 = 125.45 EUR: the new base amount, then the cart
      # IS in the base currency, so the line carries it unconverted.
      assert Decimal.equal?(line.base_unit_price, dec("125.45"))
      assert Decimal.equal?(line.unit_price, dec("125.45"))
    end
  end

  describe "round trip" do
    test "USD -> EUR -> USD returns the original amounts" do
      cart = usd_cart_with(product!(), 3)
      before = cart

      {:ok, eur} = Shop.redenominate_cart(cart, "EUR")
      assert eur.currency == "EUR"
      assert {:ok, back} = Shop.redenominate_cart(eur, "USD")

      assert %{currency: "USD", base_currency: "USD"} = back
      assert Decimal.equal?(back.exchange_rate, before.exchange_rate)
      [was] = before.items
      [now] = back.items
      assert now.currency == "USD"

      for field <- [:unit_price, :base_unit_price, :compare_at_price, :line_total] do
        assert Decimal.equal?(Map.fetch!(now, field), Map.fetch!(was, field)), "#{field} drifted"
      end

      for field <- [:subtotal, :shipping_amount, :tax_amount, :total] do
        assert Decimal.equal?(Map.fetch!(back, field), Map.fetch!(before, field)),
               "#{field} drifted"
      end
    end

    test "compare_at_price may move by one cent on a round trip; the charged amounts never do" do
      {:ok, _} =
        Billing.update_currency(Billing.get_currency_by_code("EUR"), %{exchange_rate: "0.615"})

      product = product!(%{"price" => dec("6.99"), "compare_at_price" => dec("9.99")})
      {:ok, usd} = Shop.add_to_cart(cart_in("USD"), product, 1)

      {:ok, eur} = Shop.redenominate_cart(usd, "EUR")
      [eur_line] = eur.items
      # 6.99 x 0.615 = 4.29885 -> 4.30; 9.99 x 0.615 = 6.14385 -> 6.14
      assert Decimal.equal?(eur_line.unit_price, dec("4.30"))
      assert Decimal.equal?(eur_line.compare_at_price, dec("6.14"))

      {:ok, back} = Shop.redenominate_cart(eur, "USD")
      [line] = back.items

      # unit price and totals: exact
      assert Decimal.equal?(line.unit_price, dec("6.99"))
      assert Decimal.equal?(back.subtotal, dec("6.99"))
      # 6.14 / 0.615 = 9.98373 -> 9.98: one cent under the 9.99 it began as
      assert Decimal.equal?(line.compare_at_price, dec("9.98"))
    end
  end

  describe "no change" do
    test "the cart's own currency is {:ok, cart} and writes nothing" do
      cart = usd_cart_with(product!(), 1)
      before = stored(cart.uuid)

      assert {:ok, same} = Shop.redenominate_cart(cart, "USD")

      assert same == cart
      assert stored(cart.uuid) == before
    end

    test "a stale struct does not convert the cart a second time" do
      cart = usd_cart_with(product!(), 1)

      assert {:ok, first} = Shop.redenominate_cart(cart, "EUR")
      after_first = stored(cart.uuid)

      # The caller still holds the USD struct (another tab got there first).
      assert {:ok, again} = Shop.redenominate_cart(cart, "EUR")

      assert again.currency == "EUR"
      assert Decimal.equal?(again.subtotal, first.subtotal)
      assert stored(cart.uuid) == after_first
    end
  end

  describe "errors leave the stored cart untouched" do
    test "an unknown currency is :currency_unavailable" do
      cart = usd_cart_with(product!(), 1)
      before = stored(cart.uuid)

      assert {:error, :currency_unavailable} = Shop.redenominate_cart(cart, "XXX")
      assert {:error, :currency_unavailable} = Shop.redenominate_cart(cart, nil)
      assert stored(cart.uuid) == before
    end

    test "a disabled currency is :currency_unavailable", %{eur: eur} do
      cart = usd_cart_with(product!(), 1)
      {:ok, _} = Billing.update_currency(eur, %{enabled: false})
      before = stored(cart.uuid)

      assert {:error, :currency_unavailable} = Shop.redenominate_cart(cart, "EUR")
      assert stored(cart.uuid) == before
    end

    test "a non-positive rate is :currency_unavailable", %{eur: eur} do
      cart = usd_cart_with(product!(), 1)

      Repo.update_all(from(c in Currency, where: c.uuid == ^eur.uuid),
        set: [exchange_rate: dec("0")]
      )

      PhoenixKit.Cache.clear(:billing_currencies)
      before = stored(cart.uuid)

      assert {:error, :currency_unavailable} = Shop.redenominate_cart(cart, "EUR")
      assert stored(cart.uuid) == before
    end

    test "a line without a base price is :no_base_price, and no other line moves" do
      cart = usd_cart_with(product!(), 1)
      {:ok, cart} = Shop.add_to_cart(cart, product!(%{"price" => dec("20.00")}), 1)
      [first, _second] = Enum.sort_by(cart.items, & &1.uuid)

      Repo.update_all(from(i in CartItem, where: i.uuid == ^first.uuid),
        set: [base_unit_price: nil]
      )

      before = stored(cart.uuid)

      assert {:error, :no_base_price} = Shop.redenominate_cart(cart, "EUR")
      assert stored(cart.uuid) == before
    end

    for status <- ["converted", "converting", "abandoned", "merged"] do
      test "a #{status} cart is :cart_not_active and is never changed" do
        cart = usd_cart_with(product!(), 1)

        Repo.update_all(
          from(c in Cart, where: c.uuid == ^cart.uuid),
          set: [status: unquote(status)]
        )

        before = stored(cart.uuid)

        assert {:error, :cart_not_active} =
                 Shop.redenominate_cart(%{cart | status: unquote(status)}, "EUR")

        # The caller's struct may still say "active": the row decides.
        assert {:error, :cart_not_active} = Shop.redenominate_cart(cart, "EUR")
        assert stored(cart.uuid) == before
      end
    end
  end

  describe "locking" do
    # Every statement that writes the cart or its lines comes after the
    # `FOR UPDATE` read of the cart row: a concurrent add or conversion waits
    # for this call, and a line is never priced from a half-written cart.
    test "the cart row is locked before anything is written" do
      cart = usd_cart_with(product!(), 1)

      queries = trace_queries(fn -> assert {:ok, _} = Shop.redenominate_cart(cart, "EUR") end)

      lock_at = Enum.find_index(queries, &cart_row_lock?/1)
      first_write = Enum.find_index(queries, &cart_write?/1)

      assert is_integer(lock_at), "no FOR UPDATE on the cart row: #{inspect(queries)}"
      assert is_integer(first_write)
      assert lock_at < first_write
    end

    test "the cart row lock is held until the surrounding transaction ends" do
      cart = usd_cart_with(product!(), 1)

      assert {:ok, true} =
               Repo.transaction(fn ->
                 {:ok, _} = Shop.redenominate_cart(cart, "EUR")
                 PhoenixKitEcommerce.CartApiFixtures.cart_row_locked?(cart.uuid)
               end)
    end

    test "the same-currency no-op takes no lock and no write" do
      cart = usd_cart_with(product!(), 1)

      queries = trace_queries(fn -> assert {:ok, _} = Shop.redenominate_cart(cart, "USD") end)

      assert queries == []
    end
  end

  # --- query tracing -----------------------------------------------------------

  defp trace_queries(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        send(test, {:query, meta.source, String.trim_leading(meta.query)})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain_queries([])
  end

  defp drain_queries(acc) do
    receive do
      {:query, source, query} -> drain_queries([{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp cart_row_lock?({"phoenix_kit_shop_carts", "SELECT" <> _ = query}),
    do: query =~ "FOR UPDATE"

  defp cart_row_lock?(_other), do: false

  defp cart_write?({source, query})
       when source in ["phoenix_kit_shop_carts", "phoenix_kit_shop_cart_items"],
       do: String.starts_with?(query, "UPDATE") or String.starts_with?(query, "INSERT")

  defp cart_write?(_other), do: false
end
