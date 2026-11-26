defmodule PhoenixKitEcommerce.ShipmentsRaceTest do
  @moduledoc """
  Two admins registering the same paid order at once get one live shipment.
  The order and the method are committed and each caller uses a real
  connection: inside one sandbox transaction the partial unique index never
  sees two concurrent inserts.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{Shipment, Shipments, ShippingMethod}
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, Parcel}
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @moduletag :integration

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    StubProvider.put(%{points: [StubProvider.point("P1")]})
    :ok
  end

  test "concurrent registrations of one order leave one live shipment" do
    {method, order} = committed_order!()

    on_exit(fn ->
      unboxed(fn ->
        # The shipments go with the order (ON DELETE CASCADE).
        Repo.delete_all(from(o in Order, where: o.uuid == ^order.uuid))
        Repo.delete_all(from(m in ShippingMethod, where: m.uuid == ^method.uuid))
      end)
    end)

    parent = self()

    tasks =
      for _caller <- 1..2 do
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Shipments.begin_shipment(order.uuid)
            end
          end)
        end)
      end

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))

    results = Task.await_many(tasks, 30_000)

    assert [{:ok, %Shipment{status: "creating"}}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, :live_shipment_exists} in results

    assert unboxed(fn ->
             Repo.aggregate(from(s in Shipment, where: s.order_uuid == ^order.uuid), :count)
           end) == 1
  end

  defp committed_order! do
    unboxed(fn ->
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Race carrier #{System.unique_integer([:positive])}",
          "price" => "4.00",
          "active" => true,
          "shipping_provider" => %{
            "provider" => "stub",
            "service" => "branch",
            "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}
          }
        })

      destination = %Destination{
        locality: %Locality{id: "L1", name: "Tallinn"},
        pickup_point: StubProvider.point("P1")
      }

      order =
        Repo.insert!(%Order{
          order_number: "SHIP-RACE-#{System.unique_integer([:positive])}",
          status: "paid",
          currency: "EUR",
          subtotal: Decimal.new("10"),
          total: Decimal.new("10"),
          billing_snapshot: %{"first_name" => "Race", "email" => "race@example.com"},
          line_items: [%{"name" => "Vase", "quantity" => 1, "total" => "10", "type" => "product"}],
          metadata: %{
            "shipping_method_uuid" => method.uuid,
            "shipping_country" => "EE",
            "shipping_provider" => %{"provider" => "stub", "service" => "branch"},
            "shipping_destination" => Destination.to_map(destination),
            "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 500})]
          }
        })

      {method, order}
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
