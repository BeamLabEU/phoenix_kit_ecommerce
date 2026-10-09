defmodule PhoenixKitEcommerce.Web.CheckoutBillingProfileTest do
  @moduledoc """
  The checkout billing step: billing's shared profile form, saving the entered
  details as a billing profile for a logged-in shopper, and reusing a saved one.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.DataCase

  @form "#checkout-billing-form"
  @save_checkbox "#checkout-save-billing-profile"

  describe "logged-in shopper with no saved profiles" do
    setup :logged_in_checkout

    test "sees the full billing form with the save box ticked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/checkout")

      assert has_element?(view, @form)
      assert has_element?(view, "#checkout-billing-type-individual")
      assert has_element?(view, "#checkout-billing-type-company")
      assert has_element?(view, "#checkout-billing-middle_name")
      assert has_element?(view, "#checkout-billing-address_line2")
      assert has_element?(view, "#checkout-billing-state")
      assert has_element?(view, "#{@save_checkbox}[checked]")
      refute has_element?(view, "#checkout-use-saved-billing")
    end

    test "saves the profile as default and the order references it", %{
      conn: conn,
      user: user,
      cart: cart
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      fill_and_continue(view, %{
        "middle_name" => "Quentin",
        "address_line2" => "Flat 4",
        "state" => "Harju",
        "phone" => "+3725555555"
      })

      confirm_order(view)

      assert [profile] = Billing.list_user_billing_profiles(user.uuid)
      assert profile.is_default
      assert profile.type == "individual"
      assert profile.first_name == "Test"
      assert profile.middle_name == "Quentin"
      assert profile.address_line2 == "Flat 4"
      assert profile.state == "Harju"
      assert profile.phone == "+3725555555"

      order = placed_order(cart)
      assert order.billing_profile_uuid == profile.uuid

      row =
        assert_activity_logged("shop.checkout_billing_profile_saved",
          actor_uuid: user.uuid,
          resource_uuid: profile.uuid
        )

      assert row.metadata["order_uuid"] == order.uuid
    end

    test "an unticked save box leaves only the order snapshot", %{
      conn: conn,
      user: user,
      cart: cart
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      fill_and_continue(view, %{"middle_name" => "Quentin", "save_profile" => false})
      confirm_order(view)

      assert Billing.list_user_billing_profiles(user.uuid) == []

      order = placed_order(cart)
      assert is_nil(order.billing_profile_uuid)
      assert order.billing_snapshot["first_name"] == "Test"
      assert order.billing_snapshot["middle_name"] == "Quentin"
      assert order.billing_snapshot["type"] == "individual"
      refute order.billing_snapshot["save_profile"]
      refute_activity_logged("shop.checkout_billing_profile_saved")
    end

    test "missing required fields show errors and hold the step", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/checkout")

      view |> form(@form, billing: %{first_name: "", last_name: "", email: ""}) |> render_change()

      refute has_element?(view, "#checkout-billing-first_name.input-error")

      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      assert has_element?(view, "#checkout-billing-first_name.input-error")
      assert has_element?(view, "#checkout-billing-last_name.input-error")
      assert has_element?(view, "#checkout-billing-email.input-error")
      assert has_element?(view, @form)
      refute has_element?(view, "button[phx-click='confirm_order']")

      # Once attempted, the form re-validates as the shopper types.
      view |> form(@form, billing: %{first_name: "Test"}) |> render_change()
      refute has_element?(view, "#checkout-billing-first_name.input-error")
      assert has_element?(view, "#checkout-billing-last_name.input-error")
    end

    test "a company needs a company name and a well-formed VAT number", %{
      conn: conn,
      user: user,
      cart: cart
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      view |> element("#checkout-billing-type-company") |> render_click()

      assert has_element?(view, "#checkout-billing-company_name")
      assert has_element?(view, "#checkout-billing-company_vat_number")
      refute has_element?(view, "#checkout-billing-first_name")

      view
      |> form(@form,
        billing: %{
          company_name: "",
          company_vat_number: "12-34",
          email: "billing@acme.test",
          country: "EE"
        }
      )
      |> render_change()

      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      assert has_element?(view, "#checkout-billing-company_name.input-error")
      assert has_element?(view, "#checkout-billing-company_vat_number.input-error")
      refute has_element?(view, "button[phx-click='confirm_order']")

      view
      |> form(@form,
        billing: %{
          company_name: "Acme OÜ",
          company_vat_number: "ee123456789",
          company_registration_number: "12345678",
          company_legal_address: "Registered Street 1"
        }
      )
      |> render_change()

      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      confirm_order(view)

      assert [profile] = Billing.list_user_billing_profiles(user.uuid)
      assert profile.type == "company"
      assert profile.company_name == "Acme OÜ"
      assert profile.company_vat_number == "EE123456789"
      assert profile.company_registration_number == "12345678"
      assert profile.company_legal_address == "Registered Street 1"
      assert profile.email == "billing@acme.test"
      assert is_nil(profile.first_name)

      assert placed_order(cart).billing_profile_uuid == profile.uuid
    end

    test "typed individual fields do not follow a switch to company", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      view |> form(@form, billing: complete_billing("EE")) |> render_change()
      view |> element("#checkout-billing-type-company") |> render_click()

      view
      |> form(@form, billing: %{company_name: "Acme OÜ", email: "billing@acme.test"})
      |> render_change()

      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      confirm_order(view)

      assert [profile] = Billing.list_user_billing_profiles(user.uuid)
      assert profile.type == "company"
      assert is_nil(profile.first_name)
      assert is_nil(profile.last_name)
    end

    test "details that stop being a valid profile at confirm roll the order back", %{
      conn: conn,
      user: user,
      cart: cart
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      fill_and_continue(view)
      assert has_element?(view, "button[phx-click='confirm_order']")

      # Review accepted these details; make them unsavable behind the form's
      # back, as a crafted or stale socket state would.
      :sys.replace_state(view.pid, fn state ->
        socket = state.socket
        data = Map.put(socket.assigns.billing_data, "last_name", "")
        %{state | socket: Phoenix.Component.assign(socket, :billing_data, data)}
      end)

      html = view |> element("button[phx-click='confirm_order']") |> render_click()

      assert html =~ "could not be saved"
      assert has_element?(view, @form)
      assert has_element?(view, "#checkout-billing-last_name.input-error")
      refute has_element?(view, "button[phx-click='confirm_order']")

      assert Billing.list_user_billing_profiles(user.uuid) == []
      assert Billing.list_user_orders(user.uuid) == []
      assert Shop.get_cart!(cart.uuid).status == "active"
      refute_activity_logged("shop.checkout_billing_profile_saved")
    end
  end

  describe "logged-in shopper with a saved profile" do
    setup :logged_in_checkout

    setup %{user: user} do
      {:ok, profile} =
        Billing.create_billing_profile(user, %{
          "first_name" => "Saved",
          "last_name" => "Person",
          "email" => "saved@example.com",
          "address_line1" => "9 Saved Road",
          "city" => "Tartu",
          "postal_code" => "50090",
          "country" => "EE"
        })

      {:ok, profile: profile}
    end

    test "the default profile is preselected and one click places the order", %{
      conn: conn,
      user: user,
      cart: cart,
      profile: profile
    } do
      assert profile.is_default

      {:ok, view, _html} = live(conn, "/checkout")

      # Straight to review - no billing form to fill.
      refute has_element?(view, @form)
      assert has_element?(view, "button[phx-click='confirm_order']")

      confirm_order(view)

      assert placed_order(cart).billing_profile_uuid == profile.uuid
      assert [_only] = Billing.list_user_billing_profiles(user.uuid)
      refute_activity_logged("shop.checkout_billing_profile_saved")
    end

    test "the billing step offers the saved profile preselected, then continues", %{
      conn: conn,
      cart: cart,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      view |> element("#checkout-review-change-billing") |> render_click()

      assert has_element?(view, "input[name='profile'][value='#{profile.uuid}'][checked]")
      assert has_element?(view, "#checkout-use-new-billing")
      refute has_element?(view, @form)

      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      confirm_order(view)

      assert placed_order(cart).billing_profile_uuid == profile.uuid
    end

    test "new details are saved as a second, non-default profile", %{
      conn: conn,
      user: user,
      cart: cart,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, "/checkout")

      view |> element("#checkout-review-change-billing") |> render_click()
      view |> element("#checkout-use-new-billing") |> render_click()

      # Blank except the account email; the save box is offered, ticked.
      assert has_element?(view, @form)
      assert has_element?(view, "#{@save_checkbox}[checked]")
      assert has_element?(view, "#checkout-use-saved-billing")
      assert has_element?(view, "#checkout-billing-email[value='#{user.email}']")
      refute has_element?(view, "#checkout-billing-first_name[value='Saved']")

      fill_and_continue(view, %{"first_name" => "Fresh"})
      confirm_order(view)

      profiles = Billing.list_user_billing_profiles(user.uuid)
      assert length(profiles) == 2

      new = Enum.find(profiles, &(&1.uuid != profile.uuid))
      assert new.first_name == "Fresh"
      refute new.is_default
      assert Enum.find(profiles, & &1.is_default).uuid == profile.uuid
      assert placed_order(cart).billing_profile_uuid == new.uuid
    end

    test "back to saved profiles returns to the selector", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/checkout")

      view |> element("#checkout-review-change-billing") |> render_click()
      view |> element("#checkout-use-new-billing") |> render_click()
      view |> element("#checkout-use-saved-billing") |> render_click()

      refute has_element?(view, @form)
      assert has_element?(view, "input[name='profile'][value='#{profile.uuid}'][checked]")
    end

    test "a profile that is not the shopper's is refused with a message", %{
      conn: conn,
      cart: cart
    } do
      other = DataCase.fixture_user()

      {:ok, foreign} =
        Billing.create_billing_profile(other, %{
          "first_name" => "Someone",
          "last_name" => "Else",
          "email" => "else@example.com"
        })

      {:ok, view, _html} = live(conn, "/checkout")

      # Past the LiveView's own ownership checks, as a stale socket would be.
      :sys.replace_state(view.pid, fn state ->
        socket = state.socket
        profiles = [foreign | socket.assigns.billing_profiles]

        socket =
          socket
          |> Phoenix.Component.assign(:billing_profiles, profiles)
          |> Phoenix.Component.assign(:selected_profile_uuid, foreign.uuid)

        %{state | socket: socket}
      end)

      html = view |> element("button[phx-click='confirm_order']") |> render_click()

      assert html =~ "not available"
      assert has_element?(view, "#checkout-use-new-billing")
      assert Shop.get_cart!(cart.uuid).status == "active"
    end
  end

  describe "guest" do
    test "is not offered a saved profile and the order carries a snapshot", %{conn: conn} do
      conn = guest_checkout(conn)
      {:ok, view, _html} = live(conn, "/checkout")

      assert has_element?(view, @form)
      refute has_element?(view, @save_checkbox)

      fill_and_continue(view, %{"middle_name" => "Quentin"})
      cart_uuid = checkout_cart_uuid(view)
      confirm_order(view)

      order = placed_order(cart_uuid)

      assert is_nil(order.billing_profile_uuid)
      assert order.billing_snapshot["middle_name"] == "Quentin"
      assert Billing.list_user_billing_profiles(order.user_uuid) == []
      refute_activity_logged("shop.checkout_billing_profile_saved")
    end

    test "cannot save a profile with a crafted save flag", %{conn: conn} do
      conn = guest_checkout(conn)
      {:ok, view, _html} = live(conn, "/checkout")

      fill_and_continue(view)

      render_change(view, "update_billing", %{"billing" => %{"save_profile" => "true"}})
      cart_uuid = checkout_cart_uuid(view)
      confirm_order(view)

      order = placed_order(cart_uuid)
      assert is_nil(order.billing_profile_uuid)
      assert Billing.list_user_billing_profiles(order.user_uuid) == []
    end
  end

  describe "default country" do
    setup :logged_in_checkout

    test "comes from the shop's default tax country when the company has none", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module("shop_default_tax_country", "de", "shop")

      {:ok, view, _html} = live(conn, "/checkout")

      assert selected_country(view) == "DE"
    end

    test "comes from the company's country", %{conn: conn} do
      PhoenixKit.Settings.update_json_setting("company_info", %{"country" => "FR"})

      {:ok, view, _html} = live(conn, "/checkout")

      assert selected_country(view) == "FR"
    end

    test "the company's country comes before the shop setting", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module("shop_default_tax_country", "DE", "shop")
      PhoenixKit.Settings.update_json_setting("company_info", %{"country" => "FR"})

      {:ok, view, _html} = live(conn, "/checkout")

      assert selected_country(view) == "FR"
    end

    test "is empty - never a guess - when nothing is configured", %{conn: conn, cart: cart} do
      {:ok, view, _html} = live(conn, "/checkout")

      assert selected_country(view) == nil
      refute has_element?(view, "#checkout-billing-country option[selected]")

      # And the form insists on one.
      view
      |> form(@form, billing: complete_billing("EE") |> Map.put("country", ""))
      |> render_change()

      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      assert has_element?(view, "label.select-error #checkout-billing-country")

      # No "EE" leaked in through billing's schema default, neither into the
      # form state nor onto the cart.
      assert :sys.get_state(view.pid).socket.assigns.billing_data["country"] == ""
      assert is_nil(Shop.get_cart!(cart.uuid).shipping_country)

      refute has_element?(view, "button[phx-click='confirm_order']")
    end
  end

  describe "cart that ships" do
    test "requires the full address", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")

      user = DataCase.fixture_user()
      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))

      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, _cart} = Shop.add_to_cart(cart, physical_product(), 1)

      {:ok, view, _html} = live(conn, "/checkout")

      view
      |> form(@form,
        billing: %{
          first_name: "Test",
          last_name: "Buyer",
          email: "buyer@example.com",
          country: "EE",
          address_line1: "",
          city: "",
          postal_code: ""
        }
      )
      |> render_change()

      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      assert has_element?(view, "#checkout-billing-address_line1.input-error")
      assert has_element?(view, "#checkout-billing-city.input-error")
      assert has_element?(view, "#checkout-billing-postal_code.input-error")
      refute has_element?(view, "button[phx-click='confirm_order']")
    end
  end

  describe "saved profile without an address on a cart that ships" do
    test "reopens the form prefilled, showing what is missing", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "always", "shop")

      user = DataCase.fixture_user()

      {:ok, _profile} =
        Billing.create_billing_profile(user, %{
          "first_name" => "Saved",
          "middle_name" => "Mid",
          "last_name" => "Person",
          "email" => "saved@example.com"
        })

      {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, _cart} = Shop.add_to_cart(cart, physical_product(), 1)

      conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))
      {:ok, view, _html} = live(conn, "/checkout")

      view |> element("button[phx-click='confirm_order']") |> render_click()

      assert has_element?(view, @form)
      assert has_element?(view, "#checkout-billing-first_name[value='Saved']")
      assert has_element?(view, "#checkout-billing-middle_name[value='Mid']")
      assert has_element?(view, "#checkout-billing-address_line1.input-error")
      # The profile exists already - saving it again is not the default.
      assert has_element?(view, @save_checkbox)
      refute has_element?(view, "#{@save_checkbox}[checked]")
      assert has_element?(view, "#checkout-use-saved-billing")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # A real user (profiles reference it) with a cart of one digital product,
  # signed in through the test scope.
  defp logged_in_checkout(%{conn: conn}) do
    user = DataCase.fixture_user()
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, digital_product(), 1)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))

    {:ok, conn: conn, user: user, cart: cart}
  end

  defp guest_checkout(conn) do
    session_id = "checkout-billing-profile-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, digital_product(), 1)

    Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
  end

  defp digital_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Billing Profile Widget"},
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
        "title" => %{"en" => "Parcel Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    product
  end

  defp fill_and_continue(view, extra \\ %{}) do
    billing = "EE" |> complete_billing("billing-profile") |> Map.merge(extra)

    view |> form(@form, billing: billing) |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()
  end

  defp confirm_order(view) do
    view |> element("button[phx-click='confirm_order']") |> render_click()
    assert_redirect(view)
  end

  defp selected_country(view) do
    view
    |> element("#checkout-billing-country")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("option[selected]")
    |> Enum.at(0)
    |> case do
      nil -> nil
      option -> option |> LazyHTML.attribute("value") |> List.first()
    end
  end

  # The one order a converted cart produced: a guest cart is handed to the
  # guest user created during conversion, so the cart names the owner.
  defp placed_order(%{uuid: cart_uuid}), do: placed_order(cart_uuid)

  defp placed_order(cart_uuid) when is_binary(cart_uuid) do
    cart = Shop.get_cart!(cart_uuid)
    assert cart.status == "converted"
    assert [order] = Billing.list_user_orders(cart.user_uuid)
    order
  end

  # A guest's cart is only known by its session; find it through the view.
  defp checkout_cart_uuid(view) do
    :sys.get_state(view.pid).socket.assigns.cart.uuid
  end
end
