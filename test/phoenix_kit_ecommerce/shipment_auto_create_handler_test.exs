defmodule PhoenixKitEcommerce.ShipmentAutoCreateHandlerTest do
  @moduledoc """
  The registration of a paid order's shipment on billing's `:paid` event
  (`ShipmentAutoCreateHandler`, setting `shop_shipping_auto_create`): off by
  default, one shipment and one carrier call per order however often the event
  is delivered, nothing for an order that is no longer paid or whose carrier
  cannot register shipments.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.OrderEvents
  alias PhoenixKitBilling.Workers.OrderEventWorker
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment, ShipmentAutoCreateHandler}
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, Parcel}
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @locality %Locality{id: "L1", name: "Tallinn", country: "EE"}

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    start_supervised!({Task.Supervisor, name: PhoenixKitEcommerce.Shipments.TaskSupervisor})
    stub(%{})
    :ok
  end

  defp stub(config),
    do: StubProvider.put(Map.merge(%{points: [StubProvider.point("P1")], notify: self()}, config))

  defp auto_create!(enabled) do
    {:ok, ^enabled} = Shop.set_shipping_auto_create(enabled)
  end

  defp method!(provider) do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => "4.00",
        "active" => true,
        "shipping_provider" => %{
          "provider" => provider,
          "service" => "branch",
          "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}
        }
      })

    method
  end

  # A shop order waiting for its payment, as checkout leaves it.
  defp order!(method, provider \\ "stub") do
    OrderFixtures.order!(%{
      "status" => "confirmed",
      "currency" => "EUR",
      "billing_snapshot" => %{
        "first_name" => "Mari",
        "last_name" => "Maasikas",
        "email" => "mari@example.com",
        "phone" => "5555 1234",
        "country" => "EE"
      },
      "metadata" => %{
        "shipping_method_uuid" => method.uuid,
        "shipping_country" => "EE",
        "shipping_provider" => %{"provider" => provider, "service" => "branch"},
        "shipping_destination" =>
          Destination.to_map(%Destination{
            locality: @locality,
            pickup_point: StubProvider.point("P1")
          }),
        "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 1200})]
      }
    })
  end

  defp paid!(order) do
    {:ok, paid} = Billing.mark_order_paid(order)
    paid
  end

  # The handler's job of billing's `:paid` event for `order`.
  defp paid_job(order) do
    handler = inspect(ShipmentAutoCreateHandler)
    worker = inspect(OrderEventWorker)

    Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
    |> Enum.find(
      &(&1.args["order_uuid"] == order.uuid and &1.args["handler"] == handler and
          &1.args["event"] == "paid")
    )
  end

  defp rows(order), do: Repo.all(from(s in Shipment, where: s.order_uuid == ^order.uuid))

  test "is registered with billing's order events" do
    assert ShipmentAutoCreateHandler in OrderEvents.handlers()
  end

  test "is off by default: a paid order gets no shipment" do
    order = order!(method!("stub")) |> paid!()

    refute Shop.shipping_auto_create?()
    assert :ok = OrderEventWorker.perform(paid_job(order))

    assert rows(order) == []
    refute_received {:stub_called, :create_shipment, _}
  end

  test "on, a paid order gets its shipment, logged as the system" do
    auto_create!(true)
    order = order!(method!("stub")) |> paid!()

    assert :ok = OrderEventWorker.perform(paid_job(order))

    assert [%Shipment{status: "created", tracking_number: "TRK-1", created_by_uuid: nil} = row] =
             rows(order)

    assert_received {:stub_called, :create_shipment, [_request]}

    entry =
      assert_activity_logged("shop.shipment_created",
        resource_uuid: row.uuid,
        metadata_has: %{"status" => "created", "provider" => "stub", "actor_role" => "system"}
      )

    assert entry.mode == "auto"
    assert entry.actor_uuid == nil
  end

  test "a retried delivery calls the carrier once" do
    auto_create!(true)
    order = order!(method!("stub")) |> paid!()
    job = paid_job(order)

    assert :ok = OrderEventWorker.perform(job)
    assert :ok = OrderEventWorker.perform(job)

    assert [%Shipment{}] = rows(order)
    assert_received {:stub_called, :create_shipment, _}
    refute_received {:stub_called, :create_shipment, _}
  end

  test "a retry after the carrier failed does not call it again" do
    auto_create!(true)
    stub(%{create: {:error, :timeout}})
    order = order!(method!("stub")) |> paid!()
    job = paid_job(order)

    capture_log(fn ->
      assert :ok = OrderEventWorker.perform(job)
      assert :ok = OrderEventWorker.perform(job)
    end)

    assert [%Shipment{status: "unknown"}] = rows(order)
    assert_received {:stub_called, :create_shipment, _}
    refute_received {:stub_called, :create_shipment, _}
  end

  test "a :paid delivered after the refund creates nothing" do
    auto_create!(true)
    order = order!(method!("stub")) |> paid!()
    {:ok, _refunded} = Billing.mark_order_refunded(order)

    assert :ok = OrderEventWorker.perform(paid_job(order))

    assert rows(order) == []
    refute_received {:stub_called, :create_shipment, _}
  end

  test "a method whose provider cannot register shipments gets nothing" do
    auto_create!(true)
    order = order!(method!("fixed"), "fixed") |> paid!()

    assert :ok = OrderEventWorker.perform(paid_job(order))

    assert rows(order) == []
  end

  test "an order that already has a shipment, even a cancelled one, gets no other" do
    auto_create!(true)
    order = order!(method!("stub")) |> paid!()

    Repo.insert!(%Shipment{
      order_uuid: order.uuid,
      provider: "stub",
      service: "branch",
      status: "cancelled"
    })

    assert :ok = OrderEventWorker.perform(paid_job(order))

    assert [%Shipment{status: "cancelled"}] = rows(order)
    refute_received {:stub_called, :create_shipment, _}
  end

  test "a shipment finished during destination checks prevents a second registration" do
    auto_create!(true)
    order = order!(method!("stub")) |> paid!()

    stub(%{
      points: fn _locality, _service, _query ->
        Repo.insert!(%Shipment{
          order_uuid: order.uuid,
          provider: "stub",
          service: "branch",
          status: "delivered"
        })

        {:ok, [StubProvider.point("P1")]}
      end
    })

    assert :ok = OrderEventWorker.perform(paid_job(order))
    assert [%Shipment{status: "delivered"}] = rows(order)
    refute_received {:stub_called, :create_shipment, _}
  end

  test "a pickup point the carrier no longer lists is left to the admin" do
    auto_create!(true)
    stub(%{points: [StubProvider.point("P2")]})
    order = order!(method!("stub")) |> paid!()

    log = capture_log(fn -> assert :ok = OrderEventWorker.perform(paid_job(order)) end)

    assert log =~ "pickup_point_unavailable"
    assert rows(order) == []
  end

  test "a carrier whose list cannot be read now is retried, nothing written" do
    auto_create!(true)
    stub(%{points: {:error, :timeout}})
    order = order!(method!("stub")) |> paid!()

    assert {:error, {:destination_unverified, "timeout"}} =
             OrderEventWorker.perform(paid_job(order))

    assert rows(order) == []
  end

  test "the error a retried job keeps names the reason's tag, never the carrier's text" do
    auto_create!(true)
    stub(%{points: {:error, {:http_status, 503, "Mari Maasikas is unknown"}}})
    order = order!(method!("stub")) |> paid!()

    capture_log(fn ->
      assert {:error, {:destination_unverified, "http_status"}} =
               OrderEventWorker.perform(paid_job(order))
    end)
  end
end
