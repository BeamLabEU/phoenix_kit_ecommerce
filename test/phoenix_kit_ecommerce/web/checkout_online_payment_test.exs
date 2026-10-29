defmodule PhoenixKitEcommerce.Web.CheckoutOnlinePaymentTest do
  @moduledoc """
  An order placed with an online payment option goes straight to the
  provider's page; a shopper who comes back, or whose payment could not be
  started, finds the order page waiting for the money (and updating when it
  arrives). Offline options and a billing without `start_order_payment/2`
  behave as they always did. The billing call is `FakeOnlinePayment`; the real
  chain is `online_payment_chain_test.exs`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.DataCase
  alias PhoenixKitEcommerce.Test.FakeOnlinePayment
  alias PhoenixKitEcommerce.Test.Repo

  @provider_url "https://pay.provider.test/session/abc"

  setup %{conn: conn} do
    on_exit(&FakeOnlinePayment.reset/0)

    user = DataCase.fixture_user()
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, digital_product(), 1)
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))

    {:ok, conn: conn, user: user, cart: cart}
  end

  describe "placing an order with an online option" do
    setup :only_online_option

    test "redirects to the provider and hands billing absolute return urls", %{conn: conn} do
      FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: @provider_url}})

      {:ok, view, _html} = live(conn, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()

      assert_redirect(view, @provider_url)

      assert_received {:start_order_payment, order, opts}
      assert order.status in ~w(pending confirmed draft)
      assert order.metadata["payment_option_type"] == "online"
      assert order.metadata["checkout_language"] == "en"

      # The test client's host (www.example.com) is not one the site serves,
      # so the return URLs fall back to the configured site URL.
      base = Routes.base_url()
      assert String.starts_with?(opts[:success_url], base)
      assert opts[:success_url] =~ ~r{/checkout/complete/#{order.uuid}\?payment=success$}

      assert opts[:cancel_url] =~ "/checkout/complete/#{order.uuid}?payment=cancelled"
      assert opts[:customer_email]
    end

    test "return urls use the host the shopper is on when the endpoint serves it", %{conn: conn} do
      FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: @provider_url}})

      {:ok, view, _html} = live(%{conn | host: "localhost"}, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()
      assert_redirect(view, @provider_url)

      assert_received {:start_order_payment, order, opts}
      assert opts[:success_url] =~ ~r{^http://localhost(/.*)?/checkout/complete/#{order.uuid}\?}
    end

    test "records the page language for the delayed confirmation", %{conn: conn} do
      PhoenixKitEcommerce.SearchFixtures.enable_languages!(["en", "de"])
      FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: @provider_url}})

      {:ok, view, _html} = live(put_test_locale(conn, "de"), "/de/checkout")
      view |> element("#checkout-confirm-order") |> render_click()
      assert_redirect(view, @provider_url)

      assert_received {:start_order_payment, order, _opts}
      assert order.metadata["checkout_language"] == "de"
    end

    test "a forged host is not used for the return urls", %{conn: conn} do
      FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: @provider_url}})

      {:ok, view, _html} = live(%{conn | host: "evil.example"}, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()
      assert_redirect(view, @provider_url)

      assert_received {:start_order_payment, _order, opts}
      refute opts[:success_url] =~ "evil.example"
      refute opts[:cancel_url] =~ "evil.example"
    end

    test "a payment that cannot start still leaves the order, on a page that says so", %{
      conn: conn,
      user: user
    } do
      FakeOnlinePayment.put_result({:error, :provider_not_available})

      {:ok, view, _html} = live(conn, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert [order] = Billing.list_user_orders(user.uuid)
      assert path =~ "/checkout/complete/#{order.uuid}"
      assert path =~ "payment=failed"
    end

    test "an order billing already holds as paid just opens its page", %{conn: conn} do
      FakeOnlinePayment.put_result({:error, :already_paid})

      {:ok, view, _html} = live(conn, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()

      {path, _flash} = assert_redirect(view)
      refute path =~ "payment="
    end

    test "a billing without start_order_payment/2 behaves as before", %{conn: conn} do
      FakeOnlinePayment.put_old_billing()

      {:ok, view, _html} = live(conn, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ "/checkout/complete/"
      refute path =~ "payment="
    end
  end

  describe "an offline option" do
    setup :only_offline_option

    test "never starts a payment", %{conn: conn} do
      FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: @provider_url}})

      {:ok, view, _html} = live(conn, "/checkout")
      view |> element("#checkout-confirm-order") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ "/checkout/complete/"
      refute_received {:start_order_payment, _, _}
    end
  end

  describe "the order page" do
    setup :only_online_option

    test "an unpaid online order waits for payment and offers Pay now", ctx do
      %{conn: conn} = ctx
      order = online_order!(ctx)

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert has_element?(view, "#awaiting-payment")
      assert has_element?(view, "#pay-now-button")
      refute has_element?(view, "#payment-processing")
      refute render(view) =~ "Order Confirmed!"
    end

    test "back from the provider it says the payment is being processed", ctx do
      order = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}?payment=success")

      assert has_element?(view, "#payment-processing")
    end

    test "back after cancelling it says so and offers Pay now", ctx do
      order = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}?payment=cancelled")

      assert has_element?(view, "#payment-cancelled")
      assert has_element?(view, "#pay-now-button")
    end

    test "a payment that could not start says so", ctx do
      order = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}?payment=failed")

      assert has_element?(view, "#payment-start-failed")
    end

    test "Pay now sends the shopper to the provider", ctx do
      order = online_order!(ctx)
      FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: @provider_url}})

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")
      view |> element("#pay-now-button") |> render_click()

      assert_redirect(view, @provider_url)
      assert_received {:start_order_payment, %{uuid: uuid}, _opts}
      assert uuid == order.uuid
    end

    test "Pay now with a failing provider stays on the page with the error", ctx do
      order = online_order!(ctx)
      FakeOnlinePayment.put_result({:error, :boom})

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")
      view |> element("#pay-now-button") |> render_click()

      assert has_element?(view, "#payment-start-failed")
      assert has_element?(view, "#pay-now-button")
    end

    test "the page turns into the confirmation when billing records the payment", ctx do
      order = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}?payment=success")
      assert has_element?(view, "#payment-processing")

      {:ok, paid} = Billing.update_order(order, %{"status" => "paid"})
      Billing.Events.broadcast_order_paid(paid)

      refute has_element?(view, "#awaiting-payment")
      refute has_element?(view, "#pay-now-button")
      assert render(view) =~ "Order Confirmed!"
    end

    test "another order's payment does not touch the page", ctx do
      order = online_order!(ctx)
      other = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")

      {:ok, paid} = Billing.update_order(other, %{"status" => "paid"})
      Billing.Events.broadcast_order_paid(paid)

      assert has_element?(view, "#awaiting-payment")
    end

    test "a cancelled order is not shown as confirmed", ctx do
      order = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")
      assert has_element?(view, "#awaiting-payment")

      {:ok, cancelled} = Billing.update_order(order, %{"status" => "cancelled"})
      Billing.Events.broadcast_order_cancelled(cancelled)

      assert has_element?(view, "#order-closed")
      refute has_element?(view, "#awaiting-payment")
      refute render(view) =~ "Order Confirmed!"
    end

    test "a failing Pay now shows its message once, inline", ctx do
      order = online_order!(ctx)
      FakeOnlinePayment.put_result({:error, :provider_not_available})

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")
      html = view |> element("#pay-now-button") |> render_click()

      assert html =~ "Online payment is not available right now"
      assert length(String.split(html, "Online payment is not available right now")) == 2
    end

    test "a billing without start_order_payment/2 shows the plain confirmation", ctx do
      order = online_order!(ctx)
      FakeOnlinePayment.put_old_billing()

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")

      refute has_element?(view, "#awaiting-payment")
      assert render(view) =~ "Order Confirmed!"
    end

    test "an offline order shows the plain confirmation", ctx do
      %{option: cod} = only_offline_option(ctx) |> Map.new()
      order = online_order!(%{ctx | option: cod})

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")

      refute has_element?(view, "#awaiting-payment")
    end

    test "a guest sees Pay now on the order their own session placed", ctx do
      order = guest_order!(ctx, "guest-own-session")

      {:ok, view, _html} =
        live(guest_conn("guest-own-session"), "/checkout/complete/#{order.uuid}")

      assert has_element?(view, "#awaiting-payment")
      assert has_element?(view, "#pay-now-button")
    end

    test "someone else's order is not shown and gives no Pay now", ctx do
      order = guest_order!(ctx, "guest-owner-session")

      assert {:error, {:live_redirect, %{to: to}}} =
               live(guest_conn("another-session"), "/checkout/complete/#{order.uuid}")

      refute to =~ "/checkout/complete/"
    end

    test "a refunded order closes the page", ctx do
      order = online_order!(ctx)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")
      # Straight to the row, so the only message the page gets is the refund's.
      Repo.update_all(from(o in Billing.Order, where: o.uuid == ^order.uuid),
        set: [status: "refunded"]
      )

      Billing.Events.broadcast_order_refunded(Billing.get_order_by_uuid(order.uuid))

      assert has_element?(view, "#order-closed")
      refute has_element?(view, "#awaiting-payment")
    end

    test "a message of no interest is ignored", ctx do
      order = online_order!(ctx)
      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")

      send(view.pid, {:something_else, %{uuid: order.uuid}})

      assert has_element?(view, "#awaiting-payment")
    end

    test "a provider that raises on Pay now leaves the page with the error", ctx do
      order = online_order!(ctx)
      FakeOnlinePayment.put_result(:raise)

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")
      view |> element("#pay-now-button") |> render_click()

      assert has_element?(view, "#payment-start-failed")
      assert has_element?(view, "#pay-now-button")
    end

    test "Pay now pushed at a paid order is ignored", ctx do
      order = online_order!(ctx)
      {:ok, _} = Billing.update_order(order, %{"status" => "paid"})

      {:ok, view, _html} = live(ctx.conn, "/checkout/complete/#{order.uuid}")

      assert render_click(view, "pay_now", %{}) =~ "Order Confirmed!"
      refute_received {:start_order_payment, _, _}
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp only_online_option(ctx) do
    deactivate_all_options()
    FakeOnlinePayment.put_result({:error, :not_set})

    option =
      ensure_option("stripe", "online", provider: "stripe", requires_billing_profile: false)

    Map.merge(ctx, %{option: option}) |> Map.to_list()
  end

  defp only_offline_option(ctx) do
    deactivate_all_options()
    option = ensure_option("cod", "offline", requires_billing_profile: false)
    Map.merge(ctx, %{option: option}) |> Map.to_list()
  end

  defp deactivate_all_options do
    for option <- Billing.list_payment_options() do
      {:ok, _} = Billing.update_payment_option(option, %{"active" => false})
    end
  end

  defp online_order!(%{user: user, option: option}) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "USD",
        "status" => "pending",
        "payment_option_uuid" => option.uuid,
        "billing_snapshot" => %{"email" => user.email},
        "line_items" => [
          %{"name" => "Thing", "quantity" => 1, "unit_price" => "10.00", "total" => "10.00"}
        ],
        "metadata" => %{"source" => "shop_checkout"}
      })

    order
  end

  # An order placed by a guest session: owned by a user the visitor is not,
  # recorded with the session that placed it.
  defp guest_order!(%{option: option}, session_id) do
    owner = DataCase.fixture_user()

    {:ok, order} =
      Billing.create_order(owner, %{
        "total" => Decimal.new("10.00"),
        "currency" => "USD",
        "status" => "pending",
        "payment_option_uuid" => option.uuid,
        "billing_snapshot" => %{"email" => owner.email},
        "line_items" => [
          %{"name" => "Thing", "quantity" => 1, "unit_price" => "10.00", "total" => "10.00"}
        ],
        "metadata" => %{"source" => "shop_checkout", "session_id" => session_id}
      })

    order
  end

  defp guest_conn(session_id) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "shop_session_id" => session_id,
      "shop_session_trusted" => true
    })
  end

  defp ensure_option(code, type, attrs) do
    attrs =
      attrs |> Keyword.put(:active, true) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    case Billing.get_payment_option_by_code(code) do
      nil ->
        {:ok, option} =
          Billing.create_payment_option(
            Map.merge(attrs, %{"name" => code, "code" => code, "type" => type})
          )

        option

      option ->
        {:ok, option} = Billing.update_payment_option(option, Map.put(attrs, "type", type))
        option
    end
  end

  defp digital_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Online Pay #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    product
  end
end
