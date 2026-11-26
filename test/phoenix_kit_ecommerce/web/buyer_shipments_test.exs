defmodule PhoenixKitEcommerce.Web.BuyerShipmentsTest do
  @moduledoc """
  What the buyer sees of an order's shipments: the carrier, the tracking number
  and the link on the account's order page and the confirmation page, only once
  the carrier has the shipment, the link only when it is a web address; the
  order's label following the shipment; the order list reading the shipments of
  a page in one query.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment}
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Test.Shipping.{NoCancelProvider, StubProvider}

  setup %{conn: conn} do
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

    Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")
    order = OrderFixtures.order!(%{"status" => "paid"})

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: order.user_uuid)), order: order}
  end

  defp shipment!(order, attrs) do
    Repo.insert!(
      struct(
        Shipment,
        Map.merge(
          %{
            order_uuid: order.uuid,
            provider: "stub",
            service: "branch",
            tracking_number: "CC#{System.unique_integer([:positive])}EE",
            tracking_url: "https://track.example.com/parcel"
          },
          attrs
        )
      )
    )
  end

  defp another_order!(order) do
    {:ok, another} =
      PhoenixKitBilling.create_order(Auth.get_user(order.user_uuid), %{
        "status" => "paid",
        "currency" => "EUR",
        "total" => Decimal.new("10.00"),
        "billing_snapshot" => %{"email" => "buyer@example.com"},
        "metadata" => %{"source" => "shop_checkout"}
      })

    another
  end

  describe "the account's order page" do
    test "shows no shipment before the carrier has it", %{conn: conn, order: order} do
      for status <- ~w(creating unknown failed) do
        Repo.delete_all(Shipment)
        shipment!(order, %{status: status})

        {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")

        refute has_element?(view, "#order-shipments"), status
        assert has_element?(view, "#order-status-badge", "Paid")
      end
    end

    test "shows the carrier, the number and the link once it is created", %{
      conn: conn,
      order: order
    } do
      shipment = shipment!(order, %{status: "created", carrier_label: "Omniva"})

      {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")

      assert has_element?(view, "#order-shipment-#{shipment.uuid}", "Omniva")
      assert has_element?(view, "#order-shipment-#{shipment.uuid}", shipment.tracking_number)

      assert has_element?(
               view,
               "#order-shipment-#{shipment.uuid}-tracking[href='https://track.example.com/parcel']"
             )
    end

    test "never renders a link that is not a web address", %{conn: conn, order: order} do
      shipment = shipment!(order, %{status: "in_transit", tracking_url: "javascript:alert(1)"})

      {:ok, view, html} = live(conn, "/dashboard/orders/#{order.uuid}")

      assert has_element?(view, "#order-shipment-#{shipment.uuid}", shipment.tracking_number)
      refute has_element?(view, "#order-shipment-#{shipment.uuid}-tracking")
      refute html =~ "javascript:"
    end

    test "the order's label follows the shipment", %{conn: conn, order: order} do
      shipment = shipment!(order, %{status: "created"})

      {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")
      assert has_element?(view, "#order-status-badge", "Paid")

      for {status, label} <- [{"in_transit", "Shipped"}, {"delivered", "Delivered"}] do
        Repo.update_all(from(s in Shipment, where: s.uuid == ^shipment.uuid),
          set: [status: status]
        )

        {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")
        assert has_element?(view, "#order-status-badge", label), status
        assert has_element?(view, "#order-summary-status", label), status
      end
    end

    test "a carrier that does not track counts as shipped once it has the parcel", %{
      conn: conn,
      order: order
    } do
      shipment!(order, %{status: "created", provider: "nocancel"})

      {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")

      assert has_element?(view, "#order-status-badge", "Shipped")
    end
  end

  describe "the confirmation page" do
    test "shows the shipment and the label that follows it", %{conn: conn, order: order} do
      shipment = shipment!(order, %{status: "ready_for_pickup"})

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert has_element?(view, "#order-shipment-#{shipment.uuid}", shipment.tracking_number)
      assert has_element?(view, "#order-shipment-#{shipment.uuid}-tracking")
      assert has_element?(view, "#order-status-badge", "Shipped")
    end
  end

  describe "the account's order list" do
    test "the status filter matches the label the buyer reads", %{conn: conn, order: order} do
      shipped = another_order!(order)
      shipment!(shipped, %{status: "in_transit"})

      {:ok, view, _html} = live(conn, "/dashboard/orders?status=shipped")
      assert has_element?(view, "#order-status-#{shipped.uuid}", "Shipped")
      refute has_element?(view, "#order-status-#{order.uuid}")

      {:ok, view, _html} = live(conn, "/dashboard/orders?status=paid")
      assert has_element?(view, "#order-status-#{order.uuid}", "Paid")
      refute has_element?(view, "#order-status-#{shipped.uuid}")
    end

    test "labels each order by its shipment, reading the shipments in one query", %{
      conn: conn,
      order: order
    } do
      shipped = another_order!(order)
      delivered = another_order!(order)
      shipment!(shipped, %{status: "in_transit"})
      shipment!(delivered, %{status: "delivered"})

      test = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "phoenix_kit_shop_shipments", do: send(test, {:shipments_query, meta})
        end,
        nil
      )

      try do
        {:ok, view, _html} = live(conn, "/dashboard/orders")

        assert has_element?(view, "#order-status-#{order.uuid}", "Paid")
        assert has_element?(view, "#order-status-#{shipped.uuid}", "Shipped")
        assert has_element?(view, "#order-status-#{delivered.uuid}", "Delivered")
      after
        :telemetry.detach(id)
      end

      # The disconnected render and the connected mount read the page once each.
      assert_received {:shipments_query, _}
      assert_received {:shipments_query, _}
      refute_received {:shipments_query, _}
    end
  end
end
