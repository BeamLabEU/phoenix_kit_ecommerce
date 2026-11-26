defmodule PhoenixKitEcommerce.OrderEmailsShippedTest do
  @moduledoc """
  The buyer's shipped email (`OrderEmails`, kind `"buyer_shipped"`, template
  `shop_order_shipped`): once per shipment through the order emails' marks,
  its own switch, a second shipment of the order with its own email, the
  carrier and the tracking in it, and when `Shipments` queues it.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.{OrderEmails, Shipment, Shipments}
  alias PhoenixKitEcommerce.Test.Shipping.{NoCancelProvider, StubProvider}
  alias PhoenixKitEcommerce.Workers.OrderEmailWorker

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)

    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
      StubProvider,
      NoCancelProvider
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    start_supervised!({Task.Supervisor, name: PhoenixKitEcommerce.Shipments.TaskSupervisor})
    StubProvider.put(%{notify: self()})

    {:ok, order} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("25.00"),
        "subtotal" => Decimal.new("20.00"),
        "currency" => "EUR",
        "status" => "paid",
        "billing_snapshot" => %{
          "first_name" => "Jane",
          "last_name" => "Doe",
          "email" => "jane@example.com"
        },
        "line_items" => [
          %{"type" => "product", "name" => "Vase", "quantity" => 1, "total" => "20.00"}
        ],
        "metadata" => %{"source" => "shop_checkout", "checkout_language" => "en"}
      })

    {:ok, order: order}
  end

  defp shipment!(order, attrs \\ %{}) do
    Repo.insert!(
      struct(
        Shipment,
        Map.merge(
          %{
            order_uuid: order.uuid,
            provider: "stub",
            service: "branch",
            status: "in_transit",
            tracking_number: "CC#{System.unique_integer([:positive])}EE",
            tracking_url: "https://track.example.com/CC1EE"
          },
          attrs
        )
      )
    )
  end

  defp deliver(order, shipment) do
    OrderEmails.deliver("buyer_shipped", Billing.get_order(order.uuid),
      shipment_uuid: shipment.uuid
    )
  end

  defp marks(order), do: Billing.get_order(order.uuid).metadata["_shop_emails"] || %{}

  defp jobs(order) do
    worker = inspect(OrderEmailWorker)

    Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
    |> Enum.filter(&(&1.args["order_uuid"] == order.uuid and &1.args["email"] == "buyer_shipped"))
  end

  test "names the carrier and the tracking, in both bodies", %{order: order} do
    shipment = shipment!(order, %{carrier_label: "Omniva"})

    assert :ok = deliver(order, shipment)

    assert_received {:email, mail}
    assert mail.to == [{"", "jane@example.com"}]
    assert mail.subject == "Your order #{order.order_number} is on its way"

    for body <- [mail.html_body, mail.text_body] do
      assert body =~ "Hello Jane Doe,"
      assert body =~ "has been sent with Omniva."
      assert body =~ shipment.tracking_number
      assert body =~ "https://track.example.com/CC1EE"
    end
  end

  test "without a carrier label names the provider", %{order: order} do
    shipment = shipment!(order)

    assert :ok = deliver(order, shipment)

    assert_received {:email, mail}
    assert mail.text_body =~ "has been sent with Stub carrier."
  end

  test "a link that is not a web address is left out", %{order: order} do
    shipment = shipment!(order, %{tracking_url: "javascript:alert(1)"})

    assert :ok = deliver(order, shipment)

    assert_received {:email, mail}
    refute mail.html_body =~ "javascript:"
    refute mail.text_body =~ "javascript:"
    refute mail.text_body =~ "Track your parcel"
    assert mail.text_body =~ shipment.tracking_number
  end

  test "is sent once per shipment, however often it is queued and delivered", %{order: order} do
    shipment = shipment!(order)

    assert :ok = OrderEmails.shipment_shipped(shipment)
    assert :ok = OrderEmails.shipment_shipped(shipment)
    assert [job] = jobs(order)

    assert :ok = OrderEmailWorker.perform(job)
    assert :ok = OrderEmailWorker.perform(job)

    assert_received {:email, _mail}
    refute_received {:email, _}
    assert marks(order) == %{"buyer_shipped:#{shipment.uuid}" => true}
  end

  test "a second shipment of the order gets its own email", %{order: order} do
    first = shipment!(order, %{status: "delivered"})
    second = shipment!(order)

    OrderEmails.shipment_shipped(first)
    OrderEmails.shipment_shipped(second)

    assert [_, _] = jobs = jobs(order)
    Enum.each(jobs, &(:ok = OrderEmailWorker.perform(&1)))

    assert_received {:email, one}
    assert_received {:email, two}

    assert [one.text_body, two.text_body]
           |> Enum.map(&(&1 =~ first.tracking_number))
           |> Enum.sort() ==
             [false, true]

    assert marks(order) == %{
             "buyer_shipped:#{first.uuid}" => true,
             "buyer_shipped:#{second.uuid}" => true
           }
  end

  test "its copy has a mark of the shipment's", %{order: order} do
    {:ok, _} = OrderEmails.set_copy_recipients("owner@example.com")
    shipment = shipment!(order)

    assert :ok = deliver(order, shipment)
    assert :ok = deliver(order, shipment)

    assert_received {:email, %{to: [{"", "jane@example.com"}]}}
    assert_received {:email, %{to: [{"", "owner@example.com"}]}}
    refute_received {:email, _}

    assert marks(order) == %{
             "buyer_shipped:#{shipment.uuid}" => true,
             "buyer_shipped_copy:#{shipment.uuid}" => true
           }
  end

  test "is not sent while its switch is off", %{order: order} do
    assert OrderEmails.shipped_emails_enabled?()
    {:ok, false} = OrderEmails.set_shipped_emails_enabled(false)
    shipment = shipment!(order)

    assert :ok = deliver(order, shipment)

    assert_no_email_sent()
    assert marks(order) == %{}
  end

  test "is not sent while the buyer's emails are off", %{order: order} do
    {:ok, false} = OrderEmails.set_buyer_emails_enabled(false)

    assert :ok = deliver(order, shipment!(order))

    assert_no_email_sent()
  end

  test "is not sent for a shipment that is not on its way, or not the order's", %{order: order} do
    {:ok, other} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("1"),
        "currency" => "EUR",
        "status" => "paid",
        "billing_snapshot" => %{"email" => "other@example.com"},
        "metadata" => %{"source" => "shop_checkout"}
      })

    assert :ok = deliver(order, shipment!(order, %{status: "created"}))
    assert :ok = deliver(order, shipment!(order, %{status: "returned"}))
    assert :ok = deliver(order, shipment!(other))

    assert_no_email_sent()
  end

  test "a provider that does not track sends it when the carrier registers the shipment",
       %{order: order} do
    shipment = shipment!(order, %{provider: "nocancel", status: "unknown", tracking_url: nil})

    assert {:ok, %Shipment{status: "created"}} =
             Shipments.enter_tracking_number(shipment, "NC-1")

    assert [%Oban.Job{args: %{"shipment_uuid" => uuid}}] = jobs(order)
    assert uuid == shipment.uuid
  end

  test "a provider that does not track sends it when the carrier answers the registration" do
    {:ok, method} =
      PhoenixKitEcommerce.create_shipping_method(%{
        "name" => "No tracking #{System.unique_integer([:positive])}",
        "price" => "4.00",
        "active" => true,
        "shipping_provider" => %{
          "provider" => "nocancel",
          "service" => "courier",
          "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}
        }
      })

    order =
      PhoenixKitEcommerce.OrderFixtures.order!(%{
        "status" => "paid",
        "metadata" => %{
          "shipping_method_uuid" => method.uuid,
          "shipping_country" => "EE",
          "shipping_provider" => %{"provider" => "nocancel", "service" => "courier"},
          "shipping_destination" => %{
            "address" => %{"street" => "Pikk 1", "city" => "Tallinn", "postcode" => "10111"}
          }
        }
      })

    assert {:ok, %Shipment{status: "created"} = shipment} = Shipments.register(order)

    assert [%Oban.Job{args: %{"shipment_uuid" => uuid}}] = jobs(order)
    assert uuid == shipment.uuid
  end

  test "a provider that tracks waits for the parcel to move", %{order: order} do
    shipment = shipment!(order, %{status: "unknown", tracking_url: nil})

    assert {:ok, %Shipment{status: "created"}} =
             Shipments.enter_tracking_number(shipment, "ST-1")

    assert jobs(order) == []
  end
end
