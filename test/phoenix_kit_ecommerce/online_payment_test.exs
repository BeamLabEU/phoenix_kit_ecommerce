defmodule PhoenixKitEcommerce.OnlinePaymentTest do
  @moduledoc """
  The seam to billing (`OnlinePayment`), what an unpaid online order does to
  the notifications, and the invoice-event handler that tells the buyer once
  the payment is recorded.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.InvoicePaymentHandler
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.OnlinePayment
  alias PhoenixKitEcommerce.SearchFixtures
  alias PhoenixKitEcommerce.Test.FakeOnlinePayment

  setup do
    on_exit(&FakeOnlinePayment.reset/0)
    FakeOnlinePayment.put_result({:ok, %{invoice: %{}, url: "https://pay.test/x"}})

    stripe = option!("stripe", "online", provider: "stripe")
    cod = option!("cod", "offline", [])
    {:ok, stripe: stripe, cod: cod}
  end

  describe "supported?/0" do
    test "is true when the billing module exports start_order_payment/2" do
      assert OnlinePayment.supported?()
    end

    test "is false on an older billing" do
      FakeOnlinePayment.put_old_billing()
      refute OnlinePayment.supported?()
    end
  end

  describe "online?/1 and awaiting?/1" do
    test "an online option's unpaid order awaits payment", %{stripe: stripe} do
      for status <- ~w(draft pending confirmed) do
        assert OnlinePayment.awaiting?(%{status: status, payment_option_uuid: stripe.uuid})
      end
    end

    test "a paid, cancelled or refunded one does not", %{stripe: stripe} do
      for status <- ~w(paid cancelled refunded) do
        refute OnlinePayment.awaiting?(%{status: status, payment_option_uuid: stripe.uuid})
      end
    end

    test "an offline option or none does not", %{cod: cod} do
      refute OnlinePayment.awaiting?(%{status: "pending", payment_option_uuid: cod.uuid})
      refute OnlinePayment.awaiting?(%{status: "pending", payment_option_uuid: nil})
    end

    test "the payment type recorded at checkout survives option changes", %{stripe: stripe} do
      order = %{
        status: "pending",
        payment_option_uuid: stripe.uuid,
        metadata: %{"payment_option_type" => "online"}
      }

      {:ok, _} = Billing.update_payment_option(stripe, %{"type" => "offline"})
      assert OnlinePayment.awaiting?(order)
    end

    test "an offline checkout does not become online after its option changes", %{cod: cod} do
      {:ok, _} = Billing.update_payment_option(cod, %{"type" => "online", "provider" => "stripe"})

      refute OnlinePayment.awaiting?(%{
               status: "pending",
               payment_option_uuid: cod.uuid,
               metadata: %{"payment_option_type" => "offline"}
             })
    end

    test "a free order does not", %{stripe: stripe} do
      refute OnlinePayment.awaiting?(%{
               status: "pending",
               payment_option_uuid: stripe.uuid,
               total: Decimal.new("0.00")
             })
    end

    test "nothing awaits on an older billing", %{stripe: stripe} do
      FakeOnlinePayment.put_old_billing()
      refute OnlinePayment.awaiting?(%{status: "pending", payment_option_uuid: stripe.uuid})
    end
  end

  describe "origin/1" do
    alias PhoenixKitEcommerce.Test.Endpoint

    defp socket(url, assigns \\ %{}),
      do: %{host_uri: URI.parse(url), endpoint: Endpoint, assigns: assigns}

    test "is the scheme and host of the socket's request when the endpoint serves it" do
      assert OnlinePayment.origin(socket("http://localhost/x?y=1")) == "http://localhost"
    end

    test "returns the site's own origin, not the client's scheme, port or spelling" do
      trusted = OnlinePayment.origin(socket("http://localhost/x"))

      assert OnlinePayment.origin(socket("https://localhost:9999/x")) == trusted
      assert OnlinePayment.origin(socket("http://LOCALHOST/x")) == trusted
    end

    test "brackets an IPv6 literal when the site base serves it" do
      original = PhoenixKit.Settings.get_setting("site_url", "")
      PhoenixKit.Settings.update_setting("site_url", "http://[::1]:4000")
      on_exit(fn -> PhoenixKit.Settings.update_setting("site_url", original) end)

      assert OnlinePayment.origin(socket("http://[::1]:4000/x")) == "http://[::1]:4000"
    end

    test "the canonical host of the page's language is served" do
      SearchFixtures.put_canonical_host_resolver!()

      # On the scheme of the site base, whatever the client wrote.
      base_scheme = Routes.base_url() |> URI.parse() |> Map.fetch!(:scheme)

      assert OnlinePayment.origin(socket("https://shop.example.de/x", %{current_locale: "de"})) ==
               "#{base_scheme}://shop.example.de"

      assert OnlinePayment.origin(socket("https://shop.example.de/x", %{current_locale: "en"})) ==
               nil
    end

    test "hosts are compared whole, case-insensitively" do
      assert OnlinePayment.origin(socket("http://localhost@evil.example/x")) == nil
      assert OnlinePayment.origin(socket("http://localhost./x")) == nil
    end

    test "a host the site does not serve is not believed" do
      assert OnlinePayment.origin(socket("https://evil.example/x")) == nil
      assert OnlinePayment.origin(socket("https://localhost.evil.example/x")) == nil
    end

    test "is nil when unknown" do
      assert OnlinePayment.origin(%{host_uri: :not_mounted}) == nil
      assert OnlinePayment.origin(%{}) == nil
    end
  end

  describe "start/2" do
    setup %{stripe: stripe} do
      {:ok,
       order: %{
         uuid: Ecto.UUID.generate(),
         order_number: "ORD-START",
         payment_option_uuid: stripe.uuid,
         billing_snapshot: %{"email" => "b@example.com"}
       }}
    end

    test "returns billing's URL", %{order: order} do
      assert {:ok, "https://pay.test/x"} = OnlinePayment.start(order, %{current_locale: "en"})
    end

    test "return urls are built on the given origin", %{order: order} do
      OnlinePayment.start(order, %{current_locale: "en"}, origin: "https://shop.example:8443")

      assert_received {:start_order_payment, _order, opts}
      assert opts[:success_url] =~ ~r{^https://shop\.example:8443/.*payment=success$}
      assert opts[:cancel_url] =~ ~r{^https://shop\.example:8443/.*payment=cancelled$}
    end

    test "a billing that raises is a failed start, not a crash", %{order: order} do
      FakeOnlinePayment.put_result(:raise)

      assert {:error, :payment_start_failed} =
               OnlinePayment.start(order, %{current_locale: "en"})
    end

    test "an order billing already holds as paid", %{order: order} do
      FakeOnlinePayment.put_result({:error, :already_paid})
      assert :paid = OnlinePayment.start(order, %{current_locale: "en"})
    end

    test "an unconfigured provider is unavailable, any other failure a failed start", %{
      order: order
    } do
      FakeOnlinePayment.put_result({:error, :provider_not_available})
      assert {:error, :payment_unavailable} = OnlinePayment.start(order, %{current_locale: "en"})

      FakeOnlinePayment.put_result({:error, %{"message" => "boom"}})
      assert {:error, :payment_start_failed} = OnlinePayment.start(order, %{current_locale: "en"})

      FakeOnlinePayment.put_result(:nonsense)
      assert {:error, :payment_start_failed} = OnlinePayment.start(order, %{current_locale: "en"})
    end
  end

  describe "order notifications" do
    setup do
      operator = create_admin_user()
      buyer = fixture_user()
      confirm_user!(buyer)
      {:ok, operator: operator, buyer: buyer}
    end

    test "an unpaid online order tells the operators, and the buyer nothing yet", ctx do
      order = order(ctx.stripe, "ORD-ONLINE-1", ctx.buyer.uuid)

      assert :ok = Notifications.order_placed(order)

      assert Enum.any?(texts(ctx.operator.uuid), &(&1 =~ "New order ORD-ONLINE-1"))

      assert Enum.any?(
               texts(ctx.operator.uuid),
               &(&1 =~ "ORD-ONLINE-1" and &1 =~ "awaiting online payment")
             )

      assert texts(ctx.buyer.uuid) == []
    end

    test "an offline order is announced as before", ctx do
      order = order(ctx.cod, "ORD-OFFLINE-1", ctx.buyer.uuid)

      assert :ok = Notifications.order_placed(order)

      refute Enum.any?(texts(ctx.operator.uuid), &(&1 =~ "awaiting online payment"))
      assert Enum.any?(texts(ctx.buyer.uuid), &(&1 =~ "Your order ORD-OFFLINE-1 is confirmed"))
    end

    test "on an older billing an online order is announced as before", ctx do
      FakeOnlinePayment.put_old_billing()
      order = order(ctx.stripe, "ORD-OLD-1", ctx.buyer.uuid)

      assert :ok = Notifications.order_placed(order)

      refute Enum.any?(texts(ctx.operator.uuid), &(&1 =~ "awaiting online payment"))
      assert Enum.any?(texts(ctx.buyer.uuid), &(&1 =~ "Your order ORD-OLD-1 is confirmed"))
    end

    test "an older billing does not confirm again when an invoice is paid", ctx do
      FakeOnlinePayment.put_old_billing()
      {:ok, placed} = real_order(ctx.stripe, ctx.buyer, "pending")
      assert :ok = Notifications.order_placed(placed)
      {:ok, paid} = Billing.update_order(placed, %{"status" => "paid"})

      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: paid.uuid})
      assert [_one_confirmation] = texts(ctx.buyer.uuid)
    end

    test "a free online order is not confirmed again when its invoice is paid", ctx do
      {:ok, placed} = real_order(ctx.stripe, ctx.buyer, "pending")

      {:ok, free} =
        Billing.update_order(placed, %{
          "line_items" => [
            %{"name" => "Free", "quantity" => 1, "unit_price" => "0", "total" => "0"}
          ],
          "subtotal" => "0",
          "total" => "0"
        })

      assert Decimal.equal?(free.total, 0)
      assert :ok = Notifications.order_placed(free)
      {:ok, paid} = Billing.update_order(free, %{"status" => "paid"})

      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: paid.uuid})
      assert [_one_confirmation] = texts(ctx.buyer.uuid)
    end

    test "the payment arriving tells the buyer, through billing's handler", ctx do
      {:ok, placed} = real_order(ctx.stripe, ctx.buyer, "pending")
      assert :ok = Notifications.order_placed(placed)
      assert texts(ctx.buyer.uuid) == []

      {:ok, paid} = Billing.update_order(placed, %{"status" => "paid"})

      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: paid.uuid})

      assert Enum.any?(
               texts(ctx.buyer.uuid),
               &(&1 =~ "Your order #{paid.order_number} is confirmed")
             )
    end

    test "the handler asks for a retry while the order has not caught up with the invoice",
         ctx do
      {:ok, unpaid} = real_order(ctx.stripe, ctx.buyer, "pending")

      assert {:error, :order_not_paid_yet} =
               InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: unpaid.uuid})

      assert texts(ctx.buyer.uuid) == []
    end

    test "redelivery of a paid event confirms the order only once", ctx do
      {:ok, paid} = real_order(ctx.stripe, ctx.buyer, "paid")
      invoice = %{order_uuid: paid.uuid}

      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, invoice)
      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, invoice)

      assert [text] = texts(ctx.buyer.uuid)
      assert text == "Your order #{paid.order_number} is confirmed"
      delivered = Billing.get_order_by_uuid(paid.uuid)
      assert delivered.metadata["source"] == "shop_checkout"
      assert delivered.metadata["_shop_payment_notified"] == true
      assert Billing.Order.revision(delivered) == Billing.Order.revision(paid)
      assert delivered.updated_at == paid.updated_at
    end

    test "a rollback loses both the notification and its delivery marker", ctx do
      {:ok, paid} = real_order(ctx.stripe, ctx.buyer, "paid")
      invoice = %{order_uuid: paid.uuid}

      assert {:error, :retry} =
               Repo.transaction(fn ->
                 assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, invoice)
                 Repo.rollback(:retry)
               end)

      assert texts(ctx.buyer.uuid) == []
      refute Billing.get_order_by_uuid(paid.uuid).metadata["_shop_payment_notified"]
      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, invoice)
      assert [_one_confirmation] = texts(ctx.buyer.uuid)
    end

    test "the delayed confirmation keeps the checkout language", ctx do
      SearchFixtures.enable_languages!(["en", "de"])

      {:ok, paid} =
        real_order(ctx.stripe, ctx.buyer, "paid", %{
          "source" => "shop_checkout",
          "checkout_language" => "de"
        })

      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: paid.uuid})

      assert [metadata] =
               Repo.all(
                 from(n in "phoenix_kit_notifications",
                   where: n.recipient_uuid == type(^ctx.buyer.uuid, Ecto.UUID),
                   select: n.metadata
                 )
               )

      assert metadata["notification_link"] ==
               Routes.path("/dashboard/orders/#{paid.uuid}", locale: "de")
    end

    test "the handler ignores other events, sources, offline and closed orders", ctx do
      {:ok, foreign} = real_order(ctx.stripe, ctx.buyer, "paid", %{"source" => "bookings"})
      {:ok, offline} = real_order(ctx.cod, ctx.buyer, "paid")
      {:ok, offline_unpaid} = real_order(ctx.cod, ctx.buyer, "pending")
      {:ok, cancelled} = real_order(ctx.stripe, ctx.buyer, "cancelled")

      for order <- [foreign, offline, offline_unpaid, cancelled] do
        assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: order.uuid})
      end

      assert :ok =
               InvoicePaymentHandler.handle_invoice_event(:refunded, %{order_uuid: cancelled.uuid})

      assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: nil})
      assert texts(ctx.buyer.uuid) == []
    end
  end

  test "the module offers its handler to billing" do
    assert PhoenixKitEcommerce.billing_invoice_event_handlers() == [InvoicePaymentHandler]
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp option!(code, type, attrs) do
    attrs = Map.new([{:active, true}, {:type, type} | attrs], fn {k, v} -> {to_string(k), v} end)

    case Billing.get_payment_option_by_code(code) do
      nil ->
        {:ok, o} =
          Billing.create_payment_option(Map.merge(attrs, %{"name" => code, "code" => code}))

        o

      o ->
        {:ok, o} = Billing.update_payment_option(o, attrs)
        o
    end
  end

  defp order(option, number, user_uuid) do
    %{
      uuid: Ecto.UUID.generate(),
      user_uuid: user_uuid,
      order_number: number,
      status: "pending",
      payment_option_uuid: option.uuid,
      metadata: %{},
      total: Decimal.new("10.00"),
      currency: "USD"
    }
  end

  defp real_order(option, user, status, metadata \\ %{"source" => "shop_checkout"}) do
    Billing.create_order(user, %{
      "total" => Decimal.new("10.00"),
      "currency" => "USD",
      "status" => status,
      "payment_option_uuid" => option.uuid,
      "billing_snapshot" => %{"email" => user.email},
      "line_items" => [
        %{"name" => "T", "quantity" => 1, "unit_price" => "10.00", "total" => "10.00"}
      ],
      "metadata" => metadata
    })
  end

  defp create_admin_user do
    user = fixture_user()
    role = Roles.get_role_by_name("Admin")
    {:ok, _} = Roles.assign_role(user, "Admin")
    {:ok, _} = Permissions.grant_permission(role.uuid, "shop.manage_carts")
    user
  end

  defp confirm_user!(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp texts(user_uuid) do
    from(n in "phoenix_kit_notifications",
      where: n.recipient_uuid == type(^user_uuid, Ecto.UUID),
      select: n.metadata
    )
    |> Repo.all()
    |> Enum.map(& &1["notification_text"])
  end
end
