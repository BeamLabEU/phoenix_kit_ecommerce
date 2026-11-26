defmodule PhoenixKitEcommerce.ShipmentsTrackingUrlTest do
  @moduledoc """
  A shipment's `tracking_url` is a web address or nothing: the admin's entry
  (`enter_tracking_number/3`) refuses any other scheme, a carrier's answer
  with one is stored without it, and `Shipments.web_url/1` is the check the
  pages render through.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{OrderFixtures, Shipments}
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, Parcel, ShipmentResult}
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    start_supervised!({Task.Supervisor, name: PhoenixKitEcommerce.Shipments.TaskSupervisor})
    :ok
  end

  defp order! do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => "4.00",
        "active" => true,
        "shipping_provider" => %{
          "provider" => "stub",
          "service" => "branch",
          "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}
        }
      })

    OrderFixtures.order!(%{
      "status" => "paid",
      "currency" => "EUR",
      "billing_snapshot" => %{
        "first_name" => "Mari",
        "email" => "mari@example.com",
        "phone" => "+3725551234",
        "country" => "EE"
      },
      "metadata" => %{
        "shipping_method_uuid" => method.uuid,
        "shipping_country" => "EE",
        "shipping_provider" => %{"provider" => "stub", "service" => "branch"},
        "shipping_destination" =>
          Destination.to_map(%Destination{
            locality: %Locality{id: "L1", name: "Tallinn", country: "EE"},
            pickup_point: StubProvider.point("P1")
          }),
        "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 500})]
      }
    })
  end

  defp register!(create) do
    StubProvider.put(%{points: [StubProvider.point("P1")], notify: self(), create: create})
    {{:ok, shipment}, log} = with_log(fn -> Shipments.register(order!()) end)
    {shipment, log}
  end

  describe "web_url/1" do
    test "keeps an http or https address with a host, and nothing else" do
      assert Shipments.web_url("https://track.example/CE1") == "https://track.example/CE1"
      assert Shipments.web_url(" HTTP://track.example/CE1 ") == "HTTP://track.example/CE1"

      for bad <- [
            "javascript:alert(document.cookie)",
            "JavaScript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "//track.example/CE1",
            "https://",
            "track.example/CE1",
            "",
            nil,
            42,
            "https://track.example/" <> String.duplicate("a", 2048)
          ] do
        assert Shipments.web_url(bad) == nil, inspect(bad)
      end
    end
  end

  describe "the admin's tracking number" do
    test "a link that is not a web address is refused and nothing is written" do
      {shipment, _log} = register!({:error, :timeout})

      assert {:error, :invalid_tracking_url} =
               Shipments.enter_tracking_number(shipment, "CE1",
                 tracking_url: "javascript:alert(document.cookie)"
               )

      assert %{status: "unknown", tracking_number: nil, tracking_url: nil} =
               Shipments.get_shipment(shipment.uuid)
    end

    test "a link longer than 2048 characters is refused" do
      {shipment, _log} = register!({:error, :timeout})
      long = "https://track.example/" <> String.duplicate("a", 2048)

      assert {:error, :invalid_tracking_url} =
               Shipments.enter_tracking_number(shipment, "CE1", tracking_url: long)

      edge = "https://track.example/" <> String.duplicate("a", 2048 - 22)
      assert String.length(edge) == 2048

      assert {:ok, %{tracking_url: ^edge}} =
               Shipments.enter_tracking_number(shipment, "CE1", tracking_url: edge)
    end

    test "a web address is stored, and no link at all is fine" do
      {first, _log} = register!({:error, :timeout})
      {second, _log} = register!({:error, :timeout})

      assert {:ok, %{tracking_url: "https://track.example/CE1"}} =
               Shipments.enter_tracking_number(first, "CE1",
                 tracking_url: " https://track.example/CE1 "
               )

      assert {:ok, %{status: "created", tracking_url: nil}} =
               Shipments.enter_tracking_number(second, "CE2", tracking_url: "")
    end
  end

  describe "the carrier's answer" do
    test "a tracking link that is not a web address is stored as none, and logged" do
      {shipment, log} =
        register!(%ShipmentResult{
          carrier_ref: "C-1",
          tracking_number: "CE3",
          tracking_url: "javascript:alert(1)"
        })

      assert %{status: "created", tracking_number: "CE3", tracking_url: nil} = shipment
      assert log =~ "tracking link"
      refute log =~ "javascript"
    end

    test "a carrier's link longer than 2048 characters is stored as none, and logged" do
      {shipment, log} =
        register!(%ShipmentResult{
          carrier_ref: "C-1",
          tracking_number: "CE5",
          tracking_url: "https://track.example/" <> String.duplicate("a", 2048)
        })

      assert %{status: "created", tracking_url: nil} = shipment
      assert log =~ "tracking link"
    end

    test "a web address from the carrier is kept" do
      {shipment, _log} =
        register!(%ShipmentResult{
          carrier_ref: "C-1",
          tracking_number: "CE4",
          tracking_url: "https://track.example/CE4"
        })

      assert shipment.tracking_url == "https://track.example/CE4"
    end
  end
end
