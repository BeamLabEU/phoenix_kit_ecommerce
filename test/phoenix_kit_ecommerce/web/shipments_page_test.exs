defmodule PhoenixKitEcommerce.Web.ShipmentsPageTest do
  @moduledoc """
  The Shipments admin page (`Web.Shipments`) against the stub carrier: the
  three sections, registering one order (with the admin's corrections) or a
  batch, the outcomes, and the actions on the rows that need the admin.

  Providers are registered through the application env (restored on exit), so
  this file does not run async.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment, Shipments}
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, Parcel, PickupPoint, ShipmentResult}
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Test.Shipping.{NoCancelProvider, StubProvider}

  @page "/en/admin/shop/shipments"
  @tallinn %Locality{id: "L1", name: "Tallinn", country: "EE"}
  @settings %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}

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

    start_supervised!({Task.Supervisor, name: PhoenixKitEcommerce.Shipments.TaskSupervisor})

    stub(%{})
    actor_uuid = Ecto.UUID.generate()
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: actor_uuid)), actor_uuid: actor_uuid}
  end

  # The order's pickup point is listed by default.
  defp stub(config) do
    StubProvider.put(
      Map.merge(
        %{
          points: [StubProvider.point("P1"), %{StubProvider.point("P2") | name: "Locker 2"}],
          localities: [@tallinn],
          notify: self()
        },
        config
      )
    )
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

  defp branch(point_id \\ "P1"),
    do: %Destination{locality: @tallinn, pickup_point: StubProvider.point(point_id)}

  defp order!(method, opts \\ []) do
    OrderFixtures.order!(%{
      "status" => Keyword.get(opts, :status, "paid"),
      "currency" => "EUR",
      "subtotal" => Decimal.new("40.00"),
      "total" => Decimal.new("44.00"),
      "billing_snapshot" => %{
        "type" => "individual",
        "first_name" => "Mari",
        "last_name" => "Maasikas",
        "email" => "mari@example.com",
        "phone" => "5555 1234",
        "country" => "EE"
      },
      "line_items" => [
        %{
          "name" => "Vase",
          "quantity" => 1,
          "unit_price" => "40.00",
          "total" => "40.00",
          "type" => "product"
        },
        OrderFixtures.shipping_line("4.00")
      ],
      "metadata" => %{
        "shipping_method_uuid" => method.uuid,
        "shipping_country" => "EE",
        "shipping_provider" => %{"provider" => method_provider(method), "service" => "branch"},
        "shipping_destination" => Destination.to_map(branch()),
        "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 1200})]
      }
    })
  end

  defp method_provider(method), do: method.metadata["shipping_provider"]["provider"]

  # A shipment in `status`, registered through the context.
  defp shipment!(method, status, opts \\ []) do
    order = order!(method)

    create =
      case status do
        "failed" ->
          {:error, {:rejected, "Phone number missing"}}

        "unknown" ->
          {:error, :timeout}

        _created ->
          %ShipmentResult{
            carrier_ref: "C-1",
            tracking_number: "TRK-#{System.unique_integer([:positive])}"
          }
      end

    stub(%{create: create})
    {:ok, shipment} = ExUnit.CaptureLog.with_log(fn -> Shipments.register(order) end) |> elem(0)
    stub(%{})

    case Keyword.get(opts, :set) do
      nil -> shipment
      changes -> set!(shipment, changes)
    end
  end

  defp set!(shipment, changes) do
    Repo.update_all(from(s in Shipment, where: s.uuid == ^shipment.uuid), set: changes)
    Shipments.get_shipment(shipment.uuid)
  end

  defp rows(order), do: Repo.all(from(s in Shipment, where: s.order_uuid == ^order.uuid))

  defp settle(view) do
    for _round <- 1..3 do
      _ = :sys.get_state(view.pid)
      render_async(view, 5_000)
    end

    :ok
  end

  defp open_page(conn, section), do: live(conn, @page <> "?section=" <> section)

  describe "To ship" do
    test "lists paid orders of a carrier that registers shipments, and no other", %{conn: conn} do
      method = method!()
      waiting = order!(method)
      pending = order!(method, status: "pending")
      shipped = order!(method)
      {:ok, _shipment} = Shipments.register(shipped)

      {:ok, fixed} =
        Shop.create_shipping_method(%{"name" => "Pickup", "price" => "0", "active" => true})

      fixed_order =
        OrderFixtures.order!(%{
          "status" => "paid",
          "metadata" => %{"shipping_method_uuid" => fixed.uuid}
        })

      {:ok, view, _html} = live(conn, @page)

      assert has_element?(view, "#shipments-sections")
      assert has_element?(view, "#to-ship-#{waiting.uuid}", waiting.order_number)
      assert has_element?(view, "#to-ship-#{waiting.uuid}", "Mari Maasikas")
      assert has_element?(view, "#to-ship-register-#{waiting.uuid}")
      refute has_element?(view, "#to-ship-#{pending.uuid}")
      refute has_element?(view, "#to-ship-#{shipped.uuid}")
      refute has_element?(view, "#to-ship-#{fixed_order.uuid}")
    end

    test "a list longer than the page shows says how many it holds", %{conn: conn} do
      order = order!(method!())
      fields = PhoenixKitBilling.Order.__schema__(:fields)
      row = Map.take(order, fields)

      copies =
        for n <- 1..Shipments.list_limit() do
          %{row | uuid: UUIDv7.generate(), order_number: "#{order.order_number}-#{n}"}
        end

      Repo.insert_all(PhoenixKitBilling.Order, copies)
      total = Shipments.list_limit() + 1

      {:ok, view, _html} = live(conn, @page)

      assert has_element?(
               view,
               "#shipments-truncated",
               "first #{Shipments.list_limit()} of #{total}"
             )

      {:ok, view, _html} = open_page(conn, "open")
      refute has_element?(view, "#shipments-truncated")
    end

    test "the carrier filter narrows the list", %{conn: conn} do
      stub_order = order!(method!("stub"))
      other_order = order!(method!("nocancel"))

      {:ok, view, _html} = live(conn, @page)
      assert has_element?(view, "#to-ship-#{other_order.uuid}")

      view |> form("#shipments-filters", %{"provider" => "stub"}) |> render_change()

      assert has_element?(view, "#to-ship-#{stub_order.uuid}")
      refute has_element?(view, "#to-ship-#{other_order.uuid}")
    end
  end

  describe "registering one order" do
    test "registers it with the carrier, shows the outcome and logs it", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      order = order!(method!())
      stub(%{create: %ShipmentResult{carrier_ref: "C-9", tracking_number: "CE900EE"}})

      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()

      assert has_element?(view, "#shipment-editor")
      assert has_element?(view, "#shipment-editor-name[value='Mari Maasikas']")
      assert has_element?(view, "#shipment-editor-parcel-0-weight[value='1200']")
      assert has_element?(view, "#shipment-editor-destination-summary", "Point P1")

      view |> form("#shipment-editor-form") |> render_submit()
      settle(view)

      assert_received {:stub_called, :create_shipment, [_request]}
      assert [%Shipment{status: "created", tracking_number: "CE900EE"} = shipment] = rows(order)

      assert has_element?(view, "#shipments-outcomes", "CE900EE")
      refute has_element?(view, "#shipment-editor")
      refute has_element?(view, "#shipments-running")
      refute has_element?(view, "#to-ship-#{order.uuid}")

      assert_activity_logged("shop.shipment_created",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "created", "provider" => "stub"}
      )
    end

    test "the admin's corrections of the recipient and the parcels are what is sent", %{
      conn: conn
    } do
      order = order!(method!())

      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()
      view |> element("#shipment-editor-add-parcel") |> render_click()

      view
      |> form("#shipment-editor-form", %{
        "recipient" => %{"name" => "Jaan Tamm", "phone" => "5123 4567"},
        "parcels" => %{
          "0" => %{
            "weight_g" => "900",
            "length_mm" => "300",
            "width_mm" => "200",
            "height_mm" => "100"
          },
          "1" => %{"weight_g" => "400"}
        }
      })
      |> render_submit()

      settle(view)

      assert_received {:stub_called, :create_shipment, [request]}
      assert request.recipient.name == "Jaan Tamm"
      assert request.recipient.phone == "+37251234567"

      assert [
               %Parcel{weight_g: 900, length_mm: 300, width_mm: 200, height_mm: 100},
               %Parcel{weight_g: 400}
             ] =
               request.parcels

      assert [%Shipment{recipient: %{"name" => "Jaan Tamm", "email" => "mari@example.com"}}] =
               rows(order)
    end

    test "a destination chosen in the editor's own lookups is what is sent", %{conn: conn} do
      order = order!(method!())

      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()

      view |> element("#shipment-editor-destination-change") |> render_click()
      settle(view)

      # The order's city is kept, its points are listed by the carrier.
      assert has_element?(view, "#shipment-editor-destination-locality-selected", "Tallinn")
      view |> element("#shipment-editor-destination-point-P2") |> render_click()

      assert has_element?(view, "#shipment-editor-destination-summary", "Locker 2")

      view |> form("#shipment-editor-form") |> render_submit()
      settle(view)

      assert [%Shipment{status: "created", destination: %{"pickup_point" => %{"id" => "P2"}}}] =
               rows(order)
    end

    test "a parcel weight that is not a number is refused in the editor", %{conn: conn} do
      order = order!(method!())

      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()

      view
      |> form("#shipment-editor-form", %{"parcels" => %{"0" => %{"weight_g" => "heavy"}}})
      |> render_submit()

      assert has_element?(view, "#shipment-editor-error")
      assert rows(order) == []
    end

    test "a definite failure is shown and the shipment waits under Needs attention", %{conn: conn} do
      order = order!(method!())
      stub(%{create: {:error, {:rejected, "Phone number missing"}}})

      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()
      view |> form("#shipment-editor-form") |> render_submit()
      settle(view)

      assert [%Shipment{status: "failed"} = shipment] = rows(order)
      assert has_element?(view, "#shipments-outcomes", "Phone number missing")

      {:ok, view, _html} = open_page(conn, "needs_attention")
      assert has_element?(view, "#shipment-#{shipment.uuid}")
      assert has_element?(view, "#shipment-error-#{shipment.uuid}", "Phone number missing")
      assert has_element?(view, "#shipment-events-#{shipment.uuid}")
      assert has_element?(view, "#shipment-retry-#{shipment.uuid}")
      refute has_element?(view, "#shipment-mark-failed-#{shipment.uuid}")
      refute has_element?(view, "#shipment-cancelled-at-carrier-#{shipment.uuid}")
    end

    test "an unknown outcome offers the tracking number and mark failed", %{conn: conn} do
      order = order!(method!())
      stub(%{create: {:error, :timeout}})

      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()

      ExUnit.CaptureLog.capture_log(fn ->
        view |> form("#shipment-editor-form") |> render_submit()
        settle(view)
      end)

      assert [%Shipment{status: "unknown"} = shipment] = rows(order)
      assert has_element?(view, "#shipments-outcomes", "carrier's portal")

      {:ok, view, _html} = open_page(conn, "needs_attention")
      assert has_element?(view, "#shipment-enter-tracking-#{shipment.uuid}")
      assert has_element?(view, "#shipment-mark-failed-#{shipment.uuid}")
      assert has_element?(view, "#shipment-cancelled-at-carrier-#{shipment.uuid}")
      refute has_element?(view, "#shipment-retry-#{shipment.uuid}")
    end
  end

  describe "registering a batch" do
    test "registers the ticked orders one at a time and shows how far it got", %{conn: conn} do
      method = method!()
      first = order!(method)
      second = order!(method)
      test = self()

      gated = fn request, _ctx ->
        send(test, {:create_waiting, self(), request.order_uuid})

        receive do
          :answer ->
            {:ok, %ShipmentResult{carrier_ref: "C", tracking_number: "T-" <> request.reference}}
        end
      end

      stub(%{create: gated})

      {:ok, view, _html} = live(conn, @page)

      view
      |> form("#to-ship-selection", %{"order_uuids" => [first.uuid, second.uuid]})
      |> render_change()

      view |> element("#shipments-register-selected") |> render_click()

      assert_receive {:create_waiting, carrier, order_uuid}, 5_000
      assert order_uuid == first.uuid
      assert has_element?(view, "#shipments-running", first.order_number)
      assert has_element?(view, "#shipments-batch-progress", "1 of 2")
      send(carrier, :answer)

      assert_receive {:create_waiting, carrier, order_uuid}, 5_000
      assert order_uuid == second.uuid
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#shipments-batch-progress", "2 of 2")
      send(carrier, :answer)
      settle(view)

      refute has_element?(view, "#shipments-running")
      assert [%Shipment{status: "created"}] = rows(first)
      assert [%Shipment{status: "created"}] = rows(second)
      assert has_element?(view, "#shipments-outcomes", "T-" <> first.order_number)
      assert has_element?(view, "#shipments-outcomes", "T-" <> second.order_number)
    end
  end

  describe "the permission while the page is open" do
    defp without_shipments,
      do:
        fake_scope(
          roles: ["Employee"],
          permissions: List.delete(shop_permissions(), "shop.manage_shipments")
        )

    test "a batch stops when the key is taken away between two orders", %{conn: conn} do
      method = method!()
      first = order!(method)
      second = order!(method)
      test = self()

      gated = fn request, _ctx ->
        send(test, {:create_waiting, self(), request.order_uuid})

        receive do
          :answer -> {:ok, %ShipmentResult{carrier_ref: "C", tracking_number: "T"}}
        end
      end

      stub(%{create: gated})
      {:ok, view, _html} = live(conn, @page)

      view
      |> form("#to-ship-selection", %{"order_uuids" => [first.uuid, second.uuid]})
      |> render_change()

      view |> element("#shipments-register-selected") |> render_click()
      assert_receive {:create_waiting, carrier, _order_uuid}, 5_000

      swap_scope(view, without_shipments())
      send(carrier, :answer)
      settle(view)

      refute_receive {:create_waiting, _carrier, _order_uuid}, 200
      assert rows(second) == []
      refute has_element?(view, "#shipments-running")
      assert render(view) =~ "permission"
    end

    test "the destination editor asks the carrier nothing once the key is gone", %{conn: conn} do
      order = order!(method!())
      {:ok, view, _html} = live(conn, @page)
      view |> element("#to-ship-register-#{order.uuid}") |> render_click()
      settle(view)

      swap_scope(view, without_shipments())
      # Any render passes the page's current scope down to the editor.
      render_click(view, "editor_change", %{})

      view |> element("#shipment-editor-destination-change") |> render_click()
      settle(view)

      refute has_element?(view, "#shipment-editor-destination-editor")
      refute_received {:stub_called, :list_pickup_points, _args}
    end

    test "a batch takes at most 50 orders", %{conn: conn} do
      order!(method!())
      {:ok, view, _html} = live(conn, @page)
      uuids = for _ <- 1..51, do: Ecto.UUID.generate()

      render_change(view, "select_orders", %{"order_uuids" => uuids})
      view |> element("#shipments-register-selected") |> render_click()

      refute has_element?(view, "#shipments-running")
      assert render(view) =~ "At most 50 orders"
      refute_received {:stub_called, :create_shipment, _args}
    end
  end

  describe "Open and Needs attention" do
    test "split the live shipments by what they wait for", %{conn: conn} do
      method = method!()
      created = shipment!(method, "created")

      stuck_at =
        DateTime.utc_now() |> DateTime.add(-11 * 60, :second) |> DateTime.truncate(:second)

      fresh = shipment!(method, "created", set: [status: "creating", submitted_at: nil])
      stuck = shipment!(method, "created", set: [status: "creating", updated_at: stuck_at])
      refunded = shipment!(method, "created")

      Repo.update_all(from(o in PhoenixKitBilling.Order, where: o.uuid == ^refunded.order_uuid),
        set: [status: "refunded"]
      )

      {:ok, view, _html} = open_page(conn, "open")
      assert has_element?(view, "#shipment-#{created.uuid}")
      assert has_element?(view, "#shipment-#{fresh.uuid}")
      refute has_element?(view, "#shipment-#{stuck.uuid}")
      refute has_element?(view, "#shipment-#{refunded.uuid}")

      assert has_element?(
               view,
               "#shipment-label-#{created.uuid}[href*='/shop-shipments/labels?ids=#{created.uuid}']"
             )

      refute has_element?(view, "#shipment-mark-failed-#{fresh.uuid}")

      {:ok, view, _html} = open_page(conn, "needs_attention")
      refute has_element?(view, "#shipment-#{created.uuid}")
      assert has_element?(view, "#shipment-#{stuck.uuid}")
      assert has_element?(view, "#shipment-mark-failed-#{stuck.uuid}")
      assert has_element?(view, "#shipment-enter-tracking-#{stuck.uuid}")
      assert has_element?(view, "#shipment-#{refunded.uuid}")
      assert has_element?(view, "#shipment-order-closed-#{refunded.uuid}")
    end

    test "a stored tracking link that is not a web address is not rendered as a link", %{
      conn: conn
    } do
      shipment = shipment!(method!(), "created", set: [tracking_url: "javascript:alert(1)"])
      safe = shipment!(method!(), "created", set: [tracking_url: "https://track.example/1"])

      {:ok, view, _html} = open_page(conn, "open")

      assert has_element?(view, "#shipment-#{shipment.uuid}", shipment.tracking_number)
      refute has_element?(view, "#shipment-#{shipment.uuid} a[href^='javascript']")
      refute render(view) =~ "javascript:alert"
      assert has_element?(view, "#shipment-#{safe.uuid} a[href='https://track.example/1']")
    end

    test "the status filter narrows a section", %{conn: conn} do
      method = method!()
      failed = shipment!(method, "failed")
      unknown = ExUnit.CaptureLog.with_log(fn -> shipment!(method, "unknown") end) |> elem(0)

      {:ok, view, _html} = live(conn, @page <> "?section=needs_attention&status=failed")
      assert has_element?(view, "#shipment-#{failed.uuid}")
      refute has_element?(view, "#shipment-#{unknown.uuid}")
    end
  end

  describe "the row actions" do
    test "retry sends a failed shipment again, with the admin's corrections", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      shipment = shipment!(method!(), "failed")

      {:ok, view, _html} = open_page(conn, "needs_attention")
      view |> element("#shipment-retry-#{shipment.uuid}") |> render_click()
      assert has_element?(view, "#shipment-editor-phone[value='5555 1234']")

      view
      |> form("#shipment-editor-form", %{"recipient" => %{"phone" => "+372 5000 0000"}})
      |> render_submit()

      settle(view)

      assert %Shipment{status: "created", recipient: %{"phone" => "+37250000000"}} =
               Shipments.get_shipment(shipment.uuid)

      assert_activity_logged("shop.shipment_retried",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "enter the tracking number of an unknown shipment", %{conn: conn, actor_uuid: actor_uuid} do
      shipment = ExUnit.CaptureLog.with_log(fn -> shipment!(method!(), "unknown") end) |> elem(0)

      {:ok, view, _html} = open_page(conn, "needs_attention")
      view |> element("#shipment-enter-tracking-#{shipment.uuid}") |> render_click()

      view
      |> form("#shipment-tracking-form", %{"tracking" => %{"tracking_number" => ""}})
      |> render_submit()

      assert has_element?(view, "#shipment-tracking-error")

      view
      |> form("#shipment-tracking-form", %{"tracking" => %{"tracking_number" => "CE555EE"}})
      |> render_submit()

      assert %Shipment{status: "created", tracking_number: "CE555EE"} =
               Shipments.get_shipment(shipment.uuid)

      refute has_element?(view, "#shipment-#{shipment.uuid}")

      assert_activity_logged("shop.shipment_tracking_entered",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "mark an unknown shipment failed", %{conn: conn, actor_uuid: actor_uuid} do
      shipment = ExUnit.CaptureLog.with_log(fn -> shipment!(method!(), "unknown") end) |> elem(0)

      {:ok, view, _html} = open_page(conn, "needs_attention")
      view |> element("#shipment-mark-failed-#{shipment.uuid}") |> render_click()

      assert %Shipment{status: "failed"} = Shipments.get_shipment(shipment.uuid)
      assert has_element?(view, "#shipment-retry-#{shipment.uuid}")

      assert_activity_logged("shop.shipment_marked_failed",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "Cancel is offered only where the carrier can cancel; Cancelled at the carrier everywhere",
         %{conn: conn} do
      cancellable = shipment!(method!("stub"), "created")
      not_cancellable = shipment!(method!("nocancel"), "created")

      {:ok, view, _html} = open_page(conn, "open")

      assert has_element?(view, "#shipment-cancel-#{cancellable.uuid}")
      refute has_element?(view, "#shipment-cancel-#{not_cancellable.uuid}")
      assert has_element?(view, "#shipment-cancelled-at-carrier-#{cancellable.uuid}")
      assert has_element?(view, "#shipment-cancelled-at-carrier-#{not_cancellable.uuid}")
    end

    test "Cancel asks the carrier, then records the shipment cancelled", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      shipment = shipment!(method!(), "created")

      {:ok, view, _html} = open_page(conn, "open")
      view |> element("#shipment-cancel-#{shipment.uuid}") |> render_click()
      refute_received {:stub_called, :cancel_shipment, _args}

      view |> element("button[phx-click='confirmed']") |> render_click()
      settle(view)

      assert_received {:stub_called, :cancel_shipment, [_ref]}
      assert %Shipment{status: "cancelled"} = Shipments.get_shipment(shipment.uuid)
      refute has_element?(view, "#shipment-#{shipment.uuid}")

      assert_activity_logged("shop.shipment_cancelled",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "a carrier that refuses the cancellation changes nothing", %{conn: conn} do
      shipment = shipment!(method!(), "created")
      stub(%{cancel: {:error, {:rejected, "Already handed over"}}})

      {:ok, view, _html} = open_page(conn, "open")
      view |> element("#shipment-cancel-#{shipment.uuid}") |> render_click()
      view |> element("button[phx-click='confirmed']") |> render_click()
      settle(view)

      assert %Shipment{status: "created"} = Shipments.get_shipment(shipment.uuid)
      assert has_element?(view, "#shipments-outcomes", "Already handed over")
    end

    test "Cancelled at the carrier records it locally, without calling the carrier", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      shipment = shipment!(method!("nocancel"), "created")

      {:ok, view, _html} = open_page(conn, "open")
      view |> element("#shipment-cancelled-at-carrier-#{shipment.uuid}") |> render_click()
      view |> element("button[phx-click='confirmed']") |> render_click()

      assert %Shipment{status: "cancelled"} = Shipments.get_shipment(shipment.uuid)
      refute_received {:stub_called, :cancel_shipment, _args}

      assert_activity_logged("shop.shipment_cancelled_at_carrier",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "Close ends a failed shipment of a refunded order, locally", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      method = method!()
      shipment = shipment!(method, "failed")
      open_order = shipment!(method, "failed")

      Repo.update_all(
        from(o in PhoenixKitBilling.Order, where: o.uuid == ^shipment.order_uuid),
        set: [status: "refunded"]
      )

      {:ok, view, _html} = open_page(conn, "needs_attention")
      refute has_element?(view, "#shipment-close-#{open_order.uuid}")
      view |> element("#shipment-close-#{shipment.uuid}") |> render_click()

      assert %Shipment{status: "cancelled"} = Shipments.get_shipment(shipment.uuid)
      refute has_element?(view, "#shipment-#{shipment.uuid}")
      refute_received {:stub_called, :cancel_shipment, _args}

      assert_activity_logged("shop.shipment_closed",
        resource_uuid: shipment.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "the ticked shipments get one labels link", %{conn: conn} do
      method = method!()
      first = shipment!(method, "created")
      second = shipment!(method, "created")

      {:ok, view, _html} = open_page(conn, "open")
      refute has_element?(view, "#shipments-print-selected")

      view
      |> form("#shipments-selection", %{"shipment_uuids" => [first.uuid, second.uuid]})
      |> render_change()

      assert has_element?(
               view,
               "#shipments-print-selected[href*='/shop-shipments/labels?ids=#{first.uuid},#{second.uuid}']"
             )
    end
  end

  test "the page needs shop.manage_shipments, its events too", %{conn: conn} do
    shipment = shipment!(method!(), "created")
    others = List.delete(shop_permissions(), "shop.manage_shipments")
    conn = put_test_scope(conn, fake_scope(roles: ["Employee"], permissions: others))

    assert {:error, {:live_redirect, %{flash: %{"error" => error}}}} = live(conn, @page)
    assert error =~ "permission"

    {:ok, view, _html} = live_narrowed(conn, @page <> "?section=open")
    render_click(view, "confirm", %{"action" => "cancelled_at_carrier", "uuid" => shipment.uuid})
    render_click(view, "confirmed", %{})

    assert %Shipment{status: "created"} = Shipments.get_shipment(shipment.uuid)
  end

  # The editor's point list is the carrier's, not narrowed by the cart.
  test "a destination typed by hand for a manual service", %{conn: conn} do
    manual = %PhoenixKitEcommerce.Shipping.Service{
      key: "branch",
      label: "To a branch",
      destination: :pickup_point,
      lookup: :manual
    }

    stub(%{services: [manual]})

    order =
      method!()
      |> order!()
      |> tap(fn order ->
        Repo.update_all(from(o in PhoenixKitBilling.Order, where: o.uuid == ^order.uuid),
          set: [
            metadata:
              Map.put(
                order.metadata,
                "shipping_destination",
                Destination.to_map(%Destination{
                  locality: %Locality{name: "Tartu"},
                  pickup_point: PickupPoint.manual("12345")
                })
              )
          ]
        )
      end)

    {:ok, view, _html} = live(conn, @page)
    view |> element("#to-ship-register-#{order.uuid}") |> render_click()
    view |> element("#shipment-editor-destination-change") |> render_click()

    view
    |> form("#shipment-editor-destination-manual-form", %{
      "manual" => %{"locality" => "Tartu", "point" => "99999"}
    })
    |> render_submit()

    assert has_element?(view, "#shipment-editor-destination-summary", "99999")

    view |> form("#shipment-editor-form") |> render_submit()
    settle(view)

    assert [%Shipment{destination: %{"pickup_point" => %{"id" => "99999"}}}] = rows(order)
  end
end
