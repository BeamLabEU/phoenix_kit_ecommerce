defmodule PhoenixKitEcommerce.API.CartViewTest do
  @moduledoc """
  The read model of a cart: what an agent sees, how the revision behaves, and
  what `changes/2` reports between two snapshots.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartView

  setup do
    ensure_currencies!()
    :ok
  end

  defp new_cart(currency \\ nil) do
    PhoenixKitBilling.Currency.put_request_currency(currency)
    {:ok, cart} = Shop.create_cart(session_id: "view-#{System.unique_integer([:positive])}")
    PhoenixKitBilling.Currency.put_request_currency(nil)
    cart
  end

  defp add!(cart, product, quantity, opts \\ []) do
    {:ok, cart} = Shop.add_to_cart(cart, product, quantity, opts ++ [via: :assistant])
    Shop.get_cart(cart.uuid)
  end

  defp method!(attrs) do
    {:ok, method} =
      Shop.create_shipping_method(
        Map.merge(
          %{
            "name" => "M#{System.unique_integer([:positive])}",
            "price" => Decimal.new("5.00"),
            "active" => true
          },
          attrs
        )
      )

    method
  end

  describe "an empty cart" do
    test "has no lines, zero totals, an open status and the empty revision" do
      view = CartView.build(Shop.get_cart(new_cart().uuid))

      assert view.status == "open"
      assert view.currency == "USD"
      assert view.lines == []
      assert view.totals.subtotal == %{amount: "0.00", currency: "USD"}
      assert view.totals.total == %{amount: "0.00", currency: "USD"}
      assert view.shipping == %{country: nil, method: nil}
      assert view.thresholds == []
      assert view.revision == CartView.revision(nil)
      assert is_binary(view.read_at)
    end

    test "empty/1 and locked/1 are the answers for a token without a row and a claimed one" do
      empty = CartView.empty("EUR")
      assert empty.status == "open" and empty.lines == [] and empty.currency == "EUR"
      assert empty.revision == CartView.revision(nil)
      assert empty.totals.total == %{amount: "0.00", currency: "EUR"}

      locked = CartView.locked("EUR")
      assert locked.status == "checking_out"
      assert locked.lines == []
      refute Map.has_key?(locked, :totals)
    end

    # The declared output schemas have no nullable types, and the public read tools omit nil values: an
    # explicit null would fail a client that validates structuredContent against outputSchema.
    test "compact/1 drops nil values at any depth and keeps empty lists, false and zero" do
      view = %{
        revision: nil,
        lines: [%{product_id: nil, quantity: 0, free: false, options: []}],
        shipping: %{country: nil, method: nil},
        nested: %{a: %{b: nil, c: "x"}}
      }

      assert CartView.compact(view) ==
               %{
                 lines: [%{quantity: 0, free: false, options: []}],
                 shipping: %{},
                 nested: %{a: %{c: "x"}}
               }

      locked = CartView.locked("EUR")

      assert CartView.compact(locked) ==
               %{status: "checking_out", read_at: locked.read_at, currency: "EUR", lines: []}
    end
  end

  describe "lines" do
    test "carry the product id, the title snapshot, two separate prices and a status" do
      product = product!(%{"price" => Decimal.new("10.00")})
      cart = new_cart() |> add!(product, 3)

      assert [line] = CartView.build(cart).lines
      assert line.product_id == product.uuid
      assert line.title =~ "Widget"
      assert line.options == []
      assert line.quantity == 3
      assert line.unit_price == %{amount: "10.00", currency: "USD"}
      assert line.line_total == %{amount: "30.00", currency: "USD"}
      assert line.status == "ok"
      assert CartView.build(cart).totals.subtotal == %{amount: "30.00", currency: "USD"}
    end

    test "show the neutral options of the line" do
      product = product_with_options!(%{"color" => ["Red", "Blue"]})
      cart = new_cart() |> add!(product, 1, selected_specs: %{"color" => "Blue"})

      assert [%{options: [%{attribute_key: "color", value_key: "blue"}]}] =
               CartView.build(cart).lines
    end

    test "are listed in the order they were added" do
      first = product!()
      second = product!()
      cart = new_cart() |> add!(first, 1) |> add!(second, 1)

      assert Enum.map(CartView.build(cart).lines, & &1.product_id) == [first.uuid, second.uuid]
    end

    test "turn unavailable when the product is archived or deleted" do
      archived = product!()
      deleted = product!()
      cart = new_cart() |> add!(archived, 1) |> add!(deleted, 1)

      {:ok, _} = Shop.update_product(archived, %{"status" => "archived"})
      {:ok, _} = Shop.delete_product(deleted)
      lines = CartView.build(Shop.get_cart(cart.uuid)).lines

      assert Enum.all?(lines, &(&1.status == "unavailable"))
      assert Enum.any?(lines, &is_nil(&1.product_id))
    end
  end

  describe "revision/1" do
    test "is stable, and changes with quantity, lines and the shipping choice" do
      a = product!()
      b = product!()
      cart = new_cart() |> add!(a, 1)
      rev1 = CartView.revision(cart)

      assert CartView.revision(Shop.get_cart(cart.uuid)) == rev1

      cart = add!(cart, a, 1)
      rev2 = CartView.revision(cart)
      assert rev2 != rev1

      cart = add!(cart, b, 1)
      rev3 = CartView.revision(cart)
      assert rev3 not in [rev1, rev2]

      method = method!(%{})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")
      rev4 = CartView.revision(Shop.get_cart(cart.uuid))
      assert rev4 not in [rev1, rev2, rev3]
    end

    test "ignores prices and the order lines were added in" do
      a = product!(%{"price" => Decimal.new("10.00")})
      b = product!(%{"price" => Decimal.new("20.00")})
      one = new_cart() |> add!(a, 2) |> add!(b, 1)
      two = new_cart() |> add!(b, 1) |> add!(a, 2)

      assert CartView.revision(one) == CartView.revision(two)

      {:ok, _} = Shop.update_product(a, %{"price" => Decimal.new("99.00")})
      assert CartView.revision(Shop.get_cart(one.uuid)) == CartView.revision(one)
    end

    test "is 16 lowercase hex characters" do
      assert CartView.revision(nil) =~ ~r/\A[0-9a-f]{16}\z/
    end
  end

  describe "snapshot/1, stamp/1 and changes/2" do
    test "report added, removed and changed lines and a changed shipping choice" do
      a = product!()
      b = product!()
      c = product!()

      before_cart = new_cart() |> add!(a, 1) |> add!(b, 2)
      old = CartView.snapshot(before_cart)

      after_cart = before_cart |> add!(c, 1) |> add!(a, 4)

      {:ok, _} =
        Shop.update_cart_item(Enum.find(after_cart.items, &(&1.product_uuid == b.uuid)), 5)

      after_cart = Shop.get_cart(after_cart.uuid)
      new = CartView.snapshot(after_cart)

      changes = CartView.changes(old, new)

      assert [%{product_id: id, from: nil, to: 1}] = changes.added
      assert id == c.uuid
      assert changes.removed == []

      assert Enum.sort_by(changes.changed, & &1.from) == [
               %{product_id: a.uuid, options: [], from: 1, to: 5},
               %{product_id: b.uuid, options: [], from: 2, to: 5}
             ]

      assert changes.shipping == nil
    end

    test "report a removed line and a shipping change" do
      a = product!()
      b = product!()
      cart = new_cart() |> add!(a, 1) |> add!(b, 1)
      old = CartView.snapshot(cart)

      {:ok, _} = Shop.remove_from_cart(Enum.find(cart.items, &(&1.product_uuid == a.uuid)))
      method = method!(%{})
      cart = Shop.get_cart(cart.uuid)
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")
      new = CartView.snapshot(Shop.get_cart(cart.uuid))

      changes = CartView.changes(old, new)

      assert [%{product_id: id, from: 1, to: nil}] = changes.removed
      assert id == a.uuid

      assert changes.shipping == %{
               from: %{method: nil, country: nil},
               to: %{method: method.uuid, country: "DE"}
             }
    end

    test "stamp/1 adds the revision and a timestamp and keeps the lines" do
      snapshot = CartView.snapshot(nil)
      stamped = CartView.stamp(snapshot)

      assert stamped["revision"] == CartView.revision(nil)
      assert is_binary(stamped["at"])
      assert stamped["lines"] == snapshot["lines"]
    end
  end

  describe "shipping and thresholds" do
    test "show the chosen method with its price and flags" do
      cart = new_cart() |> add!(physical_product!(), 1)
      method = method!(%{"name" => "Courier", "price" => Decimal.new("7.50")})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      view = CartView.build(Shop.get_cart(cart.uuid))

      assert view.shipping.country == "DE"

      assert %{
               id: id,
               name: "Courier",
               price: %{amount: "7.50", currency: "USD"},
               free: false,
               pay_on_delivery: false
             } =
               view.shipping.method

      assert id == method.uuid
      assert view.totals.shipping == %{amount: "7.50", currency: "USD"}
    end

    test "report each limit of the chosen method, in base, current and remaining" do
      cart = new_cart() |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 1)

      method =
        method!(%{
          "min_order_amount" => Decimal.new("5.00"),
          "max_order_amount" => Decimal.new("500.00"),
          "free_above_amount" => Decimal.new("20.00")
        })

      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")
      thresholds = CartView.build(Shop.get_cart(cart.uuid)).thresholds |> Map.new(&{&1.type, &1})

      assert Map.keys(thresholds) |> Enum.sort() == ["free_shipping", "max_order", "min_order"]
      assert thresholds["free_shipping"].method == method.uuid
      assert thresholds["free_shipping"].base == %{amount: "20.00", currency: "USD"}
      assert thresholds["free_shipping"].current == %{amount: "10.00", currency: "USD"}
      assert thresholds["free_shipping"].remaining == %{amount: "10.00", currency: "USD"}
      assert thresholds["min_order"].remaining == %{amount: "0.00", currency: "USD"}
      assert thresholds["max_order"].remaining == %{amount: "490.00", currency: "USD"}
    end

    test "without a chosen method the cheapest available one supplies the limits" do
      cart = new_cart() |> add!(physical_product!(), 1)

      _dear =
        method!(%{"price" => Decimal.new("9.00"), "free_above_amount" => Decimal.new("100.00")})

      cheap =
        method!(%{"price" => Decimal.new("2.00"), "free_above_amount" => Decimal.new("40.00")})

      assert [%{type: "free_shipping", method: method_id, base: %{amount: "40.00"}}] =
               CartView.build(Shop.get_cart(cart.uuid)).thresholds

      assert method_id == cheap.uuid
    end

    test "on a cart in another currency, current and remaining are in that currency, base stays base" do
      cart = new_cart("EUR") |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 1)
      method = method!(%{"free_above_amount" => Decimal.new("20.00")})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      assert [threshold] = CartView.build(Shop.get_cart(cart.uuid)).thresholds
      assert threshold.base == %{amount: "20.00", currency: "USD"}
      assert threshold.current.currency == "EUR"
      assert threshold.remaining.currency == "EUR"
    end

    test "an empty cart has no thresholds" do
      method!(%{"free_above_amount" => Decimal.new("20.00")})
      assert CartView.build(Shop.get_cart(new_cart().uuid)).thresholds == []
    end
  end

  describe "Shop.cart_amount_to_base/2 and cart_amount_from_base/2" do
    test "are the identity on a base-currency cart and invert each other on a converted one" do
      usd = Shop.get_cart(new_cart().uuid)
      assert Shop.cart_amount_to_base(usd, Decimal.new("10.00")) == Decimal.new("10.00")
      assert Shop.cart_amount_from_base(Decimal.new("10.00"), usd) == Decimal.new("10.00")

      eur = Shop.get_cart(new_cart("EUR").uuid)
      in_eur = Shop.cart_amount_from_base(Decimal.new("10.00"), eur)
      assert Decimal.compare(in_eur, Decimal.new("10.00")) == :lt
      assert Decimal.equal?(Shop.cart_amount_to_base(eur, in_eur), Decimal.new("10.00"))
    end
  end
end
