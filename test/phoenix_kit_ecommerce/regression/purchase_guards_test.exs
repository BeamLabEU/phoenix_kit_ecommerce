defmodule PhoenixKitEcommerce.Regression.PurchaseGuardsTest do
  @moduledoc """
  Regression guards for the context-layer purchase rules.

  Each of these was enforced only in a LiveView (or not at all), and every
  LiveView gate is skippable: `convert_cart_to_order/2` and `add_to_cart/4`
  are public and re-exported through `compat/shop.ex`, a connected view
  outlives an admin flipping the module off, and a crafted `confirm_order`
  event never runs the review step's validation.

  Runs `async: false` — these touch the global `shop_enabled` setting.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop

  defp physical_product(attrs \\ %{}) do
    {:ok, product} =
      Map.merge(
        %{
          "title" => %{"en" => "Physical Widget"},
          "price" => Decimal.new("25.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "physical",
          "requires_shipping" => true,
          "weight_grams" => 500
        },
        attrs
      )
      |> Shop.create_product()

    product
  end

  defp digital_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Digital Download"},
        "price" => Decimal.new("9.99"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    product
  end

  defp shipping_method(attrs \\ %{}) do
    {:ok, method} =
      Map.merge(
        %{"name" => "Standard", "price" => Decimal.new("5.00"), "active" => true},
        attrs
      )
      |> Shop.create_shipping_method()

    method
  end

  defp new_cart do
    {:ok, cart} = Shop.create_cart(session_id: "guards-#{System.unique_integer([:positive])}")
    cart
  end

  defp complete_billing do
    %{
      "email" => "guard-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }
  end

  describe "module enablement" do
    test "add_to_cart refuses while the shop is disabled" do
      product = physical_product()
      cart = new_cart()

      Settings.update_setting("shop_enabled", "false")
      on_exit(fn -> Settings.update_setting("shop_enabled", "true") end)

      assert {:error, :shop_disabled} = Shop.add_to_cart(cart, product, 1)
    end

    test "convert_cart_to_order refuses while the shop is disabled" do
      product = physical_product()
      method = shipping_method()
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      Settings.update_setting("shop_enabled", "false")
      on_exit(fn -> Settings.update_setting("shop_enabled", "true") end)

      assert {:error, :shop_disabled} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing())
    end
  end

  describe "product availability" do
    test "add_to_cart refuses a product that is no longer active" do
      product = physical_product()
      cart = new_cart()
      {:ok, _archived} = Shop.update_product(product, %{"status" => "archived"})

      assert {:error, {:product_not_available, _uuid}} = Shop.add_to_cart(cart, product, 1)
    end

    test "conversion refuses a cart whose product was archived after it was added" do
      product = physical_product()
      method = shipping_method()
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      {:ok, _archived} = Shop.update_product(product, %{"status" => "archived"})

      assert {:error, :product_not_available} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing())
    end
  end

  describe "shipping requirement" do
    test "a digital-only cart needs no shipping method and is charged none" do
      product = digital_product()
      _method = shipping_method()
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)

      refute Shop.cart_requires_shipping?(cart)
      assert Decimal.equal?(cart.shipping_amount || Decimal.new("0"), Decimal.new("0"))

      # No shipping method selected, yet conversion succeeds.
      assert {:ok, order} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing())

      # ... and the order carries no shipping line.
      refute Enum.any?(order.line_items, &(&1["type"] == "shipping"))
    end

    test "a physical cart still requires a shipping method" do
      product = physical_product()
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)

      assert Shop.cart_requires_shipping?(cart)

      assert {:error, :no_shipping_method} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing())
    end

    test "a mixed cart requires shipping, and digital weight does not count toward eligibility" do
      heavy_digital =
        physical_product(%{
          "title" => %{"en" => "Heavy Digital"},
          "requires_shipping" => false,
          "product_type" => "digital",
          "weight_grams" => 50_000
        })

      light_physical = physical_product(%{"weight_grams" => 100})
      light_only = shipping_method(%{"name" => "Light Parcel", "max_weight_grams" => 1_000})

      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, heavy_digital, 1)
      {:ok, cart} = Shop.add_to_cart(cart, light_physical, 1)

      assert Shop.cart_requires_shipping?(cart)

      # The 50kg digital line must not disqualify the light-parcel method.
      methods = Shop.get_available_shipping_methods(cart)
      assert Enum.any?(methods, &(&1.uuid == light_only.uuid))
    end
  end

  describe "billing completeness" do
    test "a shippable order refuses billing data without an address" do
      product = physical_product()
      method = shipping_method()
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      assert {:error, {:billing_incomplete, missing}} =
               Shop.convert_cart_to_order(cart,
                 billing_data: %{"email" => "no-address@example.com", "country" => "US"}
               )

      assert "address_line1" in missing
      assert "city" in missing
    end

    test "a digital-only order converts with email alone" do
      product = digital_product()
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)

      assert {:ok, _order} =
               Shop.convert_cart_to_order(cart,
                 billing_data: %{
                   "email" => "digital-#{System.unique_integer([:positive])}@example.com",
                   "country" => "US"
                 }
               )
    end
  end

  describe "cart snapshots" do
    test "the line snapshots the cart's currency and the visitor's language" do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Bottle", "ru" => "Бутылка"},
          "slug" => %{"en" => "bottle", "ru" => "butylka"},
          "price" => Decimal.new("25.00"),
          "status" => "active",
          # Deliberately NOT the cart currency: importers leave the schema
          # default in place, and line amounts are summed in the cart frame.
          "currency" => "USD",
          "requires_shipping" => true
        })

      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1, language: "ru")

      [item] = cart.items
      assert item.product_title == "Бутылка"
      assert item.product_slug == "butylka"
      assert item.currency == cart.currency
      assert item.metadata["requires_shipping"] == true
    end
  end
end
