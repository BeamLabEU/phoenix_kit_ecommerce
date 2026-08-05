defmodule PhoenixKitEcommerce.Regression.MoneyRoundTwoTest do
  @moduledoc """
  Guards for the money defects an adversarial review round found in the
  first pass's own fixes — the "sweep N+1 finds bugs in sweep N" family.

  Each is a case where two code paths that must agree about money did not.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options

  defp product(attrs) do
    {:ok, p} =
      Map.merge(
        %{
          "title" => %{"en" => "M2 #{System.unique_integer([:positive])}"},
          "price" => Decimal.new("20.00"),
          "status" => "active",
          "currency" => "USD",
          "requires_shipping" => true,
          "weight_grams" => 100
        },
        attrs
      )
      |> Shop.create_product()

    p
  end

  defp method(attrs) do
    {:ok, m} =
      Map.merge(
        %{
          "name" => "M#{System.unique_integer([:positive])}",
          "price" => Decimal.new("5.00"),
          "active" => true
        },
        attrs
      )
      |> Shop.create_shipping_method()

    m
  end

  defp cart, do: elem(Shop.create_cart(session_id: "m2-#{System.unique_integer([:positive])}"), 1)

  defp billing do
    %{
      "email" => "m2-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "T",
      "last_name" => "B",
      "address_line1" => "1 St",
      "city" => "C",
      "postal_code" => "1",
      "country" => "US"
    }
  end

  test "conversion judges the selected method on SHIPPABLE weight, like listing and pricing do" do
    heavy_digital =
      product(%{
        "requires_shipping" => false,
        "product_type" => "digital",
        "weight_grams" => 50_000
      })

    light = product(%{"weight_grams" => 100})
    light_parcel = method(%{"max_weight_grams" => 1_000})

    c = cart()
    {:ok, c} = Shop.add_to_cart(c, heavy_digital, 1)
    {:ok, c} = Shop.add_to_cart(c, light, 1)

    # The method IS offered (pricing sees 100g of shippable weight)...
    assert Enum.any?(Shop.get_available_shipping_methods(c), &(&1.uuid == light_parcel.uuid))

    {:ok, c} = Shop.set_cart_shipping(c, light_parcel, "US")

    # ...so conversion must not then refuse it by re-judging on the 50kg
    # digital line's weight.
    assert {:ok, _order} = Shop.convert_cart_to_order(c, billing_data: billing())
  end

  test "a cart that loses its last physical line converts despite a leftover method" do
    physical = product(%{})

    digital =
      product(%{"requires_shipping" => false, "product_type" => "digital", "weight_grams" => 0})

    heavy_only = method(%{"min_weight_grams" => 50})

    c = cart()
    {:ok, c} = Shop.add_to_cart(c, physical, 1)
    {:ok, c} = Shop.add_to_cart(c, digital, 1)
    {:ok, c} = Shop.set_cart_shipping(c, heavy_only, "US")

    physical_item = Enum.find(c.items, &(&1.product_uuid == physical.uuid))
    {:ok, c} = Shop.remove_from_cart(physical_item)

    # Nothing ships now: the stale selection is irrelevant, not a blocker.
    refute Shop.cart_requires_shipping?(c)
    assert {:ok, order} = Shop.convert_cart_to_order(c, billing_data: billing())
    refute Enum.any?(order.line_items, &(&1["type"] == "shipping"))
  end

  test "the cheapest shipping method is chosen by VALUE, not Erlang term order" do
    # %Decimal{coef: 999, exp: -2} (9.99) sorts ABOVE %Decimal{coef: 10,
    # exp: 0} (10) in term order - the same trap that made price ranges
    # come out inverted.
    cheap = method(%{"name" => "Cheap", "price" => Decimal.new("9.99")})
    dear = method(%{"name" => "Dear", "price" => Decimal.new("10")})

    c = cart()
    {:ok, c} = Shop.add_to_cart(c, product(%{}), 1)

    {:ok, c} = Shop.auto_select_shipping_method(c, [dear, cheap])

    assert c.shipping_method_uuid == cheap.uuid
  end

  test "the advertised range and the charged price agree for map-shaped overrides" do
    # The documented override shape. The charged path parsed it; the range
    # path did not, so the catalog quoted a price the cart disagreed with.
    specs = [
      %{
        "key" => "tier",
        "label" => "Tier",
        "type" => "select",
        "options" => ["Base", "Premium"],
        "affects_price" => true,
        "allow_override" => true,
        "modifier_type" => "fixed",
        "price_modifiers" => %{}
      }
    ]

    metadata = %{
      "_option_values" => %{"tier" => ["Base", "Premium"]},
      "_price_modifiers" => %{"tier" => %{"Premium" => %{"type" => "fixed", "value" => "10.00"}}}
    }

    {min_price, max_price} = Options.get_price_range(specs, Decimal.new("20.00"), metadata)

    charged =
      Options.calculate_final_price(specs, %{"tier" => "Premium"}, Decimal.new("20.00"), metadata)

    assert Decimal.equal?(min_price, Decimal.new("20.00"))
    # The range's top end must be what the customer is actually charged.
    assert Decimal.equal?(max_price, charged)
  end
end
