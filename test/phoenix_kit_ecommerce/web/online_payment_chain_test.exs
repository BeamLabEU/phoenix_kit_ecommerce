defmodule PhoenixKitEcommerce.Web.OnlinePaymentChainTest do
  @moduledoc """
  The whole chain with the real billing and a Stripe answered by `Req.Test`
  (billing's `:stripe_req_options` seam): Confirm Order opens a checkout
  session on a `sent` invoice and redirects to its URL, the provider's
  webhook pays the invoice and the order, the open order page updates, and
  the buyer is told. Needs a billing that has `start_order_payment/2`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :billing_start_order_payment

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.WebhookProcessor
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.DataCase
  alias PhoenixKitEcommerce.InvoicePaymentHandler
  alias PhoenixKitEcommerce.Test.Repo

  setup %{conn: conn} do
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_chain")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:stripe_body, URI.decode_query(body)})

      Req.Test.json(conn, %{
        "id" => "cs_chain_1",
        "url" => "https://checkout.stripe.test/cs_chain_1",
        "expires_at" => System.os_time(:second) + 86_400
      })
    end)

    for option <- Billing.list_payment_options() do
      {:ok, _} = Billing.update_payment_option(option, %{"active" => false})
    end

    stripe = Billing.get_payment_option_by_code("stripe")

    {:ok, _} =
      Billing.update_payment_option(stripe, %{
        "active" => true,
        "type" => "online",
        "provider" => "stripe",
        "requires_billing_profile" => false
      })

    user = DataCase.fixture_user()

    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, product(), 2)

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))
    {:ok, conn: conn, user: user, cart: cart}
  end

  test "Confirm Order, the provider's webhook, and the page that was waiting", ctx do
    %{conn: conn, user: user} = ctx

    {:ok, view, _html} = live(conn, "/checkout")
    view |> element("#checkout-confirm-order") |> render_click()
    assert_redirect(view, "https://checkout.stripe.test/cs_chain_1")

    [order] = Billing.list_user_orders(user.uuid)
    assert order.status == "pending"
    [invoice] = Billing.list_invoices_for_order(order.uuid)
    assert invoice.status == "sent"

    assert_received {:stripe_body, params}
    assert params["metadata[invoice_uuid]"] == invoice.uuid
    assert params["success_url"] =~ "/checkout/complete/#{order.uuid}?payment=success"

    # The shopper is back before the webhook: the page says so.
    {:ok, page, _html} = live(conn, "/checkout/complete/#{order.uuid}?payment=success")
    assert has_element?(page, "#payment-processing")

    # The operator was told at once, the buyer only after the payment.
    # (The first registered user is the shop's Owner, so they hear as operator too.)
    assert Enum.any?(user_texts(user.uuid), &(&1 =~ "awaiting online payment"))
    refute Enum.any?(user_texts(user.uuid), &(&1 =~ "is confirmed"))

    assert {:ok, _paid} =
             WebhookProcessor.process(%{
               event_id: "evt_chain_#{System.unique_integer([:positive])}",
               provider: :stripe,
               type: "checkout.completed",
               data: %{
                 mode: "payment",
                 invoice_uuid: invoice.uuid,
                 amount_total: Decimal.to_integer(Decimal.mult(order.total, 100)),
                 currency: order.currency,
                 payment_intent_id: "pi_chain"
               }
             })

    assert Billing.get_order_by_uuid(order.uuid).status == "paid"

    # The open page follows the payment (billing's PubSub event).
    assert render(page) =~ "Order Confirmed!"
    refute has_element?(page, "#awaiting-payment")

    # And billing's durable handler tells the buyer.
    assert :ok = InvoicePaymentHandler.handle_invoice_event(:paid, %{order_uuid: order.uuid})
    assert Enum.any?(user_texts(user.uuid), &(&1 =~ "is confirmed"))
  end

  test "a second Confirm Order or Pay now reuses the invoice and the session", ctx do
    %{conn: conn, user: user} = ctx

    {:ok, view, _html} = live(conn, "/checkout")
    view |> element("#checkout-confirm-order") |> render_click()
    assert_redirect(view, "https://checkout.stripe.test/cs_chain_1")

    [order] = Billing.list_user_orders(user.uuid)

    {:ok, page, _html} = live(conn, "/checkout/complete/#{order.uuid}?payment=cancelled")
    page |> element("#pay-now-button") |> render_click()
    assert_redirect(page, "https://checkout.stripe.test/cs_chain_1")

    assert [_one] = Billing.list_invoices_for_order(order.uuid)
    assert_received {:stripe_body, _first}
    refute_received {:stripe_body, _second}
  end

  defp user_texts(user_uuid) do
    import Ecto.Query, only: [from: 2]

    from(n in "phoenix_kit_notifications",
      where: n.recipient_uuid == type(^user_uuid, Ecto.UUID),
      select: n.metadata
    )
    |> Repo.all()
    |> Enum.map(& &1["notification_text"])
  end

  defp product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Chain #{System.unique_integer([:positive])}"},
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
