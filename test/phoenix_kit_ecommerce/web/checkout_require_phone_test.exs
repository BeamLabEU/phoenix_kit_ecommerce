defmodule PhoenixKitEcommerce.Web.CheckoutRequirePhoneTest do
  @moduledoc """
  The "Require a phone number at checkout" setting: off by default, and on it
  makes the checkout billing step refuse a blank phone. Billing may or may not
  know the `require_phone` option (`BillingSupport`); the checkout must behave
  the same either way, only the input's required mark depends on billing.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.BillingSupport
  alias PhoenixKitEcommerce.DataCase

  @form "#checkout-billing-form"
  @phone "+3725555555"

  # Decided before any test overrides the probe.
  @billing_supports_phone BillingSupport.supported?()

  setup %{conn: conn} do
    # The settings cache is ETS-backed and is not rolled back by the sandbox.
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", false, "shop")
      Application.delete_env(:phoenix_kit_ecommerce, :billing_require_phone_support)
    end)

    user = DataCase.fixture_user()
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, _cart} = Shop.add_to_cart(cart, digital_product(), 1)

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))}
  end

  test "the setting is off by default" do
    refute Shop.require_phone_at_checkout?()
    assert BillingSupport.phone_attrs(Shop.require_phone_at_checkout?()) == []
  end

  describe "setting off" do
    test "a blank phone is accepted and the input is not marked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/checkout")

      refute has_element?(view, "#checkout-billing-phone[required]")
      refute continue(view, %{}) =~ "Please fill in all required fields"
    end
  end

  for supported <- [false, true] do
    describe "setting on, billing #{if supported, do: "with", else: "without"} the option" do
      @describetag supported: supported

      if supported and not @billing_supports_phone do
        @describetag skip: "the installed billing has no require_phone option"
      end

      setup %{supported: supported} do
        Application.put_env(:phoenix_kit_ecommerce, :billing_require_phone_support, supported)

        Settings.update_boolean_setting_with_module(
          "shop_require_phone_at_checkout",
          true,
          "shop"
        )

        :ok
      end

      test "a blank phone blocks the billing step, a phone lets it through", %{conn: conn} do
        {:ok, blank, _html} = live(conn, "/checkout")

        assert continue(blank, %{}) =~ "Please fill in all required fields"
        assert render(blank) =~ "can&#39;t be blank"

        # A fresh session: the flash of the first attempt would outlive the fix.
        {:ok, filled, _html} = live(conn, "/checkout")

        refute continue(filled, %{"phone" => @phone}) =~ "Please fill in all required fields"
      end

      test "a whitespace-only phone counts as blank", %{conn: conn} do
        {:ok, view, _html} = live(conn, "/checkout")

        assert continue(view, %{"phone" => "   "}) =~ "Please fill in all required fields"
      end

      if supported do
        test "the input is marked required", %{conn: conn} do
          {:ok, view, _html} = live(conn, "/checkout")

          assert has_element?(view, "#checkout-billing-phone[required]")
        end
      end
    end
  end

  describe "a saved profile without a phone" do
    setup %{conn: conn} do
      user = DataCase.fixture_user()

      {:ok, profile} =
        Billing.create_billing_profile(user, %{
          "first_name" => "Saved",
          "last_name" => "Person",
          "email" => "saved@example.com",
          "country" => "EE"
        })

      {:ok, with_phone} =
        Billing.create_billing_profile(user, %{
          "first_name" => "Phoned",
          "last_name" => "Person",
          "email" => "phoned@example.com",
          "country" => "EE",
          "phone" => @phone
        })

      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, cart} = Shop.add_to_cart(cart, digital_product(), 1)
      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))

      {:ok, conn: conn, user: user, cart: cart, profile: profile, with_phone: with_phone}
    end

    test "is refused by the order conversion when the phone is required", ctx do
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", true, "shop")

      assert {:error, {:billing_incomplete, ["phone"]}} =
               Shop.convert_cart_to_order(ctx.cart,
                 user_uuid: ctx.user.uuid,
                 billing_profile_uuid: ctx.profile.uuid
               )

      assert Shop.get_cart!(ctx.cart.uuid).status == "active"
    end

    test "and so are billing details without one", ctx do
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", true, "shop")

      data = %{
        "email" => "x@example.com",
        "first_name" => "Ann",
        "country" => "EE",
        "phone" => " "
      }

      assert {:error, {:billing_incomplete, ["phone"]}} =
               Shop.convert_cart_to_order(ctx.cart, user_uuid: ctx.user.uuid, billing_data: data)
    end

    test "converts when the setting is off", ctx do
      assert {:ok, _order} =
               Shop.convert_cart_to_order(ctx.cart,
                 user_uuid: ctx.user.uuid,
                 billing_profile_uuid: ctx.profile.uuid
               )
    end

    test "a profile with a phone converts when the phone is required", ctx do
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", true, "shop")

      assert {:ok, _order} =
               Shop.convert_cart_to_order(ctx.cart,
                 user_uuid: ctx.user.uuid,
                 billing_profile_uuid: ctx.with_phone.uuid
               )
    end

    test "sends the shopper back to an editable form that asks for the phone",
         %{conn: conn} = ctx do
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", true, "shop")
      Billing.update_billing_profile(ctx.with_phone, %{"is_default" => false})
      Billing.update_billing_profile(ctx.profile, %{"is_default" => true})

      {:ok, view, _html} = live(conn, "/checkout")

      html = view |> element("button[phx-click='confirm_order']") |> render_click()

      assert html =~ "Please add a phone number"
      assert has_element?(view, @form)
      assert has_element?(view, "#checkout-billing-first_name[value='Saved']")
      assert has_element?(view, "#checkout-billing-phone.input-error")
      assert Shop.get_cart!(ctx.cart.uuid).status == "active"
    end
  end

  describe "a checkout without a billing step" do
    setup %{conn: conn} do
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", true, "shop")

      user = DataCase.fixture_user()
      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, cart} = Shop.add_to_cart(cart, digital_product(), 1)

      # Only one active option, and it needs no billing profile: mount lands on
      # review with the billing form never filled in.
      case Billing.get_payment_option_by_code("cod") do
        nil -> :ok
        cod -> {:ok, _} = Billing.update_payment_option(cod, %{"active" => false})
      end

      {:ok, _option} = billing_less_option()

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))
      {:ok, conn: conn, user: user, cart: cart}
    end

    test "the phone setting does not introduce one", %{conn: conn, cart: cart} do
      {:ok, view, _html} = live(conn, "/checkout")

      refute has_element?(view, @form)

      view |> element("button[phx-click='confirm_order']") |> render_click()
      assert_redirect(view)

      assert Shop.get_cart!(cart.uuid).status == "converted"
    end

    test "and the order conversion asks nothing of the blank form data", ctx do
      blank = %{
        "first_name" => "",
        "last_name" => "",
        "email" => ctx.user.email,
        "country" => "EE"
      }

      assert {:ok, _order} =
               Shop.convert_cart_to_order(ctx.cart, user_uuid: ctx.user.uuid, billing_data: blank)
    end
  end

  describe "a saved profile that lacks the address and the phone" do
    test "the shopper is told about both", %{conn: conn} do
      Settings.update_boolean_setting_with_module("shop_require_phone_at_checkout", true, "shop")
      Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")

      on_exit(fn ->
        Settings.update_setting_with_module("shop_shipping_skip_mode", "off", "shop")
      end)

      user = DataCase.fixture_user()

      {:ok, _profile} =
        Billing.create_billing_profile(user, %{
          "first_name" => "Saved",
          "last_name" => "Person",
          "email" => "saved@example.com"
        })

      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, _cart} = Shop.add_to_cart(cart, physical_product(), 1)

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))
      {:ok, view, _html} = live(conn, "/checkout")

      html = view |> element("button[phx-click='confirm_order']") |> render_click()

      assert html =~ "Please complete your billing details and add a phone number"
      assert has_element?(view, "#checkout-billing-phone.input-error")
      assert has_element?(view, "#checkout-billing-address_line1.input-error")
    end
  end

  defp continue(view, extra) do
    billing = "EE" |> complete_billing("billing-profile") |> Map.merge(extra)

    view |> form(@form, billing: billing) |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()
  end

  defp digital_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Require Phone Widget #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    product
  end

  defp physical_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Require Phone Parcel #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    product
  end

  # Core seeds a row per payment option code; flip one to "no billing profile".
  defp billing_less_option do
    attrs = %{"active" => true, "requires_billing_profile" => false}

    case Billing.get_payment_option_by_code("stripe") do
      nil ->
        Billing.create_payment_option(
          Map.merge(attrs, %{
            "name" => "stripe",
            "code" => "stripe",
            "type" => "online",
            "provider" => "stripe"
          })
        )

      option ->
        Billing.update_payment_option(option, Map.put(attrs, "provider", "stripe"))
    end
  end
end
