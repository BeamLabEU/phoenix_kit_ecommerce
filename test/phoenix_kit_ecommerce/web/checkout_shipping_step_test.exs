defmodule PhoenixKitEcommerce.Web.CheckoutShippingStepTest do
  @moduledoc """
  The checkout-time shipping step (`shop_shipping_selection_position: "checkout"`):
  it only appears after billing, filters methods by the billing country just
  captured, and honors `shop_shipping_skip_mode` the same way the conversion
  context does (`PhoenixKitEcommerce.ConvertSkipShippingTest` covers that side).
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  test "position=checkout: shipping step appears after billing with country-filtered methods",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    # Covers "EE" only - the billing form below uses that country, so the
    # step must offer it.
    method = shipping_method(countries: ["EE"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    html = view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert html =~ "id=\"checkout-shipping-step\""
    assert has_element?(view, "#checkout-shipping-method-#{method.uuid}")
    refute has_element?(view, "#checkout-shipping-fallback-notice")
    refute has_element?(view, "#checkout-shipping-blocked")

    view
    |> element("#checkout-shipping-method-#{method.uuid} input[type='radio']")
    |> render_click()

    html = view |> element("#checkout-shipping-continue") |> render_click()

    # Reached review, and the chosen method shows up on it.
    assert has_element?(view, "button[phx-click='confirm_order']")
    assert html =~ method.name
  end

  test "fallback + uncovered country shows contact notice and proceeds to review",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "fallback", "shop")

    # Covers "US" only - the billing form below uses "EE", which nothing serves.
    _method = shipping_method(countries: ["US"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-fallback-notice")
    refute has_element?(view, "#checkout-shipping-blocked")

    view |> element("#checkout-shipping-continue") |> render_click()

    assert has_element?(view, "button[phx-click='confirm_order']")
  end

  test "off + uncovered country blocks at shipping step", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    # skip_mode stays at the "off" default - nothing may skip.
    _method = shipping_method(countries: ["US"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-blocked")
    refute has_element?(view, "#checkout-shipping-continue")
    refute has_element?(view, "button[phx-click='confirm_order']")

    # Belt and suspenders: even a crafted "shipping_continue" event (no
    # matching DOM affordance exists to fire it) must not move the step.
    render_click(view, "shipping_continue", %{})
    refute has_element?(view, "button[phx-click='confirm_order']")
    assert has_element?(view, "#checkout-shipping-blocked")
  end

  defp fill_billing_form(view, country: country) do
    form(view, "#checkout-billing-form",
      billing: %{
        "first_name" => "Test",
        "last_name" => "Buyer",
        "email" => "checkout-shipping-#{System.unique_integer([:positive])}@example.com",
        "address_line1" => "1 Test Street",
        "city" => "Testville",
        "postal_code" => "10001",
        "country" => country
      }
    )
  end

  defp shipping_method(attrs) do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Standard",
        "price" => Decimal.new("5.00"),
        "active" => true,
        "countries" => Keyword.fetch!(attrs, :countries)
      })

    method
  end

  # A guest session with one physical (shippable) item in its cart - the
  # same pattern `CartPageShippingModesTest` and `CheckoutSignalTest` use.
  defp setup_shippable_cart_session(conn) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Shipping Step Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    session_id = "checkout-shipping-step-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
  end
end
