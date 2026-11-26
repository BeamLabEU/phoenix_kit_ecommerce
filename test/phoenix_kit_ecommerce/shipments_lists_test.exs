defmodule PhoenixKitEcommerce.ShipmentsListsTest do
  @moduledoc """
  The admin's lists of `PhoenixKitEcommerce.Shipments` (`list_to_ship/1`,
  `list_open/1`, `list_needs_attention/1`, `count_sections/1`) and the draft
  the Shipments page starts its editor from (`shipment_draft/2`).
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment, Shipments}
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, Parcel, ShipmentResult}
  alias PhoenixKitEcommerce.Test.Shipping.{NoCancelProvider, StubProvider}

  @locality %Locality{id: "L1", name: "Tallinn", country: "EE"}
  @settings %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}

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
    StubProvider.put(%{points: [StubProvider.point("P1")], notify: self()})
    :ok
  end

  defp method!(provider \\ "stub") do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => "4.00",
        "active" => true,
        "shipping_provider" => %{
          "provider" => provider,
          "service" => "branch",
          "settings" => @settings
        }
      })

    method
  end

  defp order!(method, status \\ "paid") do
    OrderFixtures.order!(%{
      "status" => status,
      "currency" => "EUR",
      "billing_snapshot" => %{
        "type" => "company",
        "company_name" => "Vaas OÜ",
        "email" => "shop@example.com",
        "phone" => "5555 1234",
        "country" => "EE"
      },
      "metadata" => %{
        "shipping_method_uuid" => method.uuid,
        "shipping_country" => "EE",
        "shipping_provider" => %{
          "provider" => method.metadata["shipping_provider"]["provider"],
          "service" => "branch"
        },
        "shipping_destination" =>
          Destination.to_map(%Destination{
            locality: @locality,
            pickup_point: StubProvider.point("P1")
          }),
        "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 700})]
      }
    })
  end

  defp register!(order, create) do
    StubProvider.put(%{points: [StubProvider.point("P1")], notify: self(), create: create})

    {{:ok, shipment}, _log} =
      ExUnit.CaptureLog.with_log(fn -> Shipments.register(order) end)

    shipment
  end

  defp set_order_status!(order, status),
    do: Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: [status: status])

  test "the three sections split the orders and shipments, and the counts agree" do
    method = method!()
    waiting = order!(method)
    _pending = order!(method, "pending")
    created = method |> order!() |> register!(%ShipmentResult{tracking_number: "T1"})
    failed = method |> order!() |> register!({:error, {:rejected, "no"}})
    unknown = method |> order!() |> register!({:error, :timeout})
    refunded_order = order!(method)
    refunded = register!(refunded_order, %ShipmentResult{tracking_number: "T2"})
    set_order_status!(refunded_order, "refunded")

    assert [{%Order{uuid: uuid}, %{uuid: method_uuid}}] = Shipments.list_to_ship()
    assert uuid == waiting.uuid
    assert method_uuid == method.uuid

    assert Enum.map(Shipments.list_open(), fn {s, _order} -> s.uuid end) == [created.uuid]

    assert Shipments.list_needs_attention()
           |> Enum.map(fn {s, _order} -> s.uuid end)
           |> Enum.sort() ==
             Enum.sort([failed.uuid, unknown.uuid, refunded.uuid])

    assert Shipments.count_sections() == %{to_ship: 1, open: 1, needs_attention: 3}

    assert Shipments.count_sections(status: "failed") == %{
             to_ship: 1,
             open: 0,
             needs_attention: 1
           }
  end

  test "an order whose shipments are all cancelled is to ship again" do
    method = method!()
    order = order!(method)
    first = register!(order, %ShipmentResult{tracking_number: "T1"})
    {:ok, _cancelled} = Shipments.mark_cancelled_at_carrier(first)

    assert [{%Order{uuid: uuid}, _method}] = Shipments.list_to_ship()
    assert uuid == order.uuid
    assert Shipments.count_sections().to_ship == 1

    # Registered again, it leaves To ship while the new shipment is live.
    _second = register!(order, %ShipmentResult{tracking_number: "T2"})
    assert Shipments.list_to_ship() == []
    assert Shipments.count_sections().to_ship == 0
  end

  test "a failed shipment of a refunded order is closed locally, one of a paid order is not" do
    method = method!()
    refunded_order = order!(method)
    refunded = register!(refunded_order, {:error, {:rejected, "no"}})
    set_order_status!(refunded_order, "refunded")
    paid = method |> order!() |> register!({:error, {:rejected, "no"}})
    actor = Ecto.UUID.generate()

    assert {:error, :order_not_closed} = Shipments.close_shipment(paid, actor_uuid: actor)
    assert Shipments.get_shipment(paid.uuid).status == "failed"

    assert {:ok, %Shipment{status: "cancelled"} = closed} =
             Shipments.close_shipment(refunded, actor_uuid: actor)

    assert %{"action" => "closed", "status" => "cancelled", "actor_uuid" => ^actor} =
             List.last(closed.events)

    refute_received {:stub_called, :cancel_shipment, _args}
    assert Enum.map(Shipments.list_needs_attention(), fn {s, _o} -> s.uuid end) == [paid.uuid]

    # Only a failed shipment is closed this way.
    assert {:error, :shipment_changed} = Shipments.close_shipment(closed)
  end

  test "the carrier filter applies to every section" do
    ours = order!(method!("stub"))
    theirs = method!("nocancel") |> order!() |> register!(%ShipmentResult{tracking_number: "T"})

    assert [{%Order{uuid: uuid}, _method}] = Shipments.list_to_ship(provider: "stub")
    assert uuid == ours.uuid
    assert Shipments.list_to_ship(provider: "nocancel") == []
    assert [{%Shipment{uuid: shipment_uuid}, _order}] = Shipments.list_open(provider: "nocancel")
    assert shipment_uuid == theirs.uuid

    assert Shipments.count_sections(provider: "stub") == %{
             to_ship: 1,
             open: 0,
             needs_attention: 0
           }
  end

  test "the carriers that register shipments are offered as filters" do
    assert {"stub", "Stub carrier"} in Shipments.shipment_providers()
    assert {"nocancel", "Carrier without cancel"} in Shipments.shipment_providers()
    refute Enum.any?(Shipments.shipment_providers(), fn {key, _label} -> key == "fixed" end)
  end

  test "the draft of an order is what begin_shipment/2 would send" do
    order = order!(method!())

    assert {:ok, draft} = Shipments.shipment_draft(order)
    assert draft.service.key == "branch"
    assert draft.context.provider == StubProvider
    assert [%Parcel{weight_g: 700}] = draft.parcels
    assert %Destination{pickup_point: %{id: "P1"}} = draft.destination

    assert %{"name" => "Vaas OÜ", "company" => "Vaas OÜ", "raw_phone" => "5555 1234"} =
             draft.recipient
  end

  test "the draft of a failed shipment is what it sent last time" do
    shipment = method!() |> order!() |> register!({:error, {:rejected, "no"}})

    assert {:ok, draft} = Shipments.shipment_draft(shipment)
    assert draft.recipient["phone"] == "+37255551234"
    assert [%Parcel{weight_g: 700}] = draft.parcels
  end

  test "stuck?/1 is a creating shipment 10 minutes without an answer" do
    now = DateTime.utc_now()

    assert Shipments.stuck?(%Shipment{status: "creating", updated_at: DateTime.add(now, -601)})
    refute Shipments.stuck?(%Shipment{status: "creating", updated_at: DateTime.add(now, -30)})
    refute Shipments.stuck?(%Shipment{status: "unknown", updated_at: DateTime.add(now, -3600)})
  end
end
