defmodule PhoenixKitEcommerce.Web.ShipmentLabelsControllerTest do
  @moduledoc """
  The label route (`GET /shop-shipments/labels?ids=...`,
  `Web.ShipmentLabelsController`): the permission it checks itself, the id
  limits, one carrier per document, and the PDF it answers with.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment, Shipments}
  alias PhoenixKitEcommerce.Shipping.{Destination, LabelOptions, Locality, Parcel, ShipmentRef}
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Test.Shipping.{NoCancelProvider, StubProvider}

  @path "/shop-shipments/labels"
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
    StubProvider.put(%{points: [StubProvider.point("P1")], notify: self()})

    actor_uuid = Ecto.UUID.generate()
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: actor_uuid)), actor_uuid: actor_uuid}
  end

  defp shipment!(provider \\ "stub") do
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

    destination = %Destination{
      locality: %Locality{id: "L1", name: "Tallinn", country: "EE"},
      pickup_point: StubProvider.point("P1")
    }

    order =
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
          "shipping_provider" => %{"provider" => provider, "service" => "branch"},
          "shipping_destination" => Destination.to_map(destination),
          "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 500})]
        }
      })

    {:ok, %{status: "created"} = shipment} = Shipments.register(order)
    shipment
  end

  defp labels(conn, ids), do: get(conn, @path <> "?ids=" <> Enum.join(ids, ","))

  defp refused_to_shipments(conn) do
    assert redirected_to(conn) =~ "/admin/shop/shipments"
    Phoenix.Flash.get(conn.assigns.flash, :error)
  end

  test "answers the carrier's PDF as an attachment, in the shop's label size", %{
    conn: conn,
    actor_uuid: actor_uuid
  } do
    first = shipment!()
    second = shipment!()

    {:ok, _} =
      PhoenixKit.Settings.update_setting_with_module("shop_shipping_label_format", "a6", "shop")

    conn = labels(conn, [first.uuid, second.uuid])

    assert conn.status == 200
    assert conn.resp_body == "%PDF-stub"
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/pdf"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ ".pdf"
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert_received {:stub_called, :print_labels, [refs, %LabelOptions{format: :a6}]}
    assert Enum.map(refs, & &1.tracking_number) == [first.tracking_number, second.tracking_number]
    assert Enum.all?(refs, &match?(%ShipmentRef{}, &1))

    assert_activity_logged("shop.shipment_labels_printed",
      actor_uuid: actor_uuid,
      metadata_has: %{"count" => 2, "format" => "a6", "provider" => "stub"}
    )
  end

  test "a scope without shop.manage_shipments is refused before anything is read", %{conn: conn} do
    shipment = shipment!()
    others = List.delete(shop_permissions(), "shop.manage_shipments")
    conn = put_test_scope(conn, fake_scope(roles: ["Employee"], permissions: others))

    conn = labels(conn, [shipment.uuid])

    assert redirected_to(conn) =~ "/admin/shop"
    refute redirected_to(conn) =~ "shipments"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    refute_received {:stub_called, :print_labels, _args}
  end

  test "no scope at all is refused" do
    shipment = shipment!()
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> labels([shipment.uuid])

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "permission"
    refute_received {:stub_called, :print_labels, _args}
  end

  test "a switched-off shop says so, not that the permission is missing", %{conn: conn} do
    shipment = shipment!()
    {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

    conn = labels(conn, [shipment.uuid])

    assert redirected_to(conn) =~ "/admin"
    refute redirected_to(conn) =~ "/shop"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "The shop is switched off."
    refute_received {:stub_called, :print_labels, _args}
  end

  test "more than 50 ids are refused", %{conn: conn} do
    ids = for _ <- 1..51, do: Ecto.UUID.generate()

    assert labels(conn, ids) |> refused_to_shipments() ==
             "At most 50 labels can be printed at once."

    refute_received {:stub_called, :print_labels, _args}
  end

  test "an id that is not a UUID is refused", %{conn: conn} do
    shipment = shipment!()

    assert labels(conn, [shipment.uuid, "1; DROP"]) |> refused_to_shipments() ==
             "The list of shipments is not valid."

    assert get(conn, @path) |> refused_to_shipments() == "The list of shipments is not valid."
    refute_received {:stub_called, :print_labels, _args}
  end

  test "shipments of two carriers are refused", %{conn: conn} do
    ours = shipment!("stub")
    theirs = shipment!("nocancel")

    assert labels(conn, [ours.uuid, theirs.uuid]) |> refused_to_shipments() ==
             "Labels can be printed together only for shipments of one carrier connection."

    refute_received {:stub_called, :print_labels, _args}
  end

  test "shipments of one carrier made in two environments (test and live) are refused", %{
    conn: conn
  } do
    live = shipment!()
    sandbox = shipment!()

    Repo.update_all(
      from(s in Shipment, where: s.uuid == ^sandbox.uuid),
      set: [context_snapshot: Map.put(sandbox.context_snapshot, "environment", "test")]
    )

    assert labels(conn, [live.uuid, sandbox.uuid]) |> refused_to_shipments() ==
             "Labels can be printed together only for shipments of one carrier connection."

    refute_received {:stub_called, :print_labels, _args}
  end

  test "a shipment the carrier has no label for, or none at all, is refused", %{conn: conn} do
    shipment = shipment!()
    {:ok, cancelled} = Shipments.mark_cancelled_at_carrier(shipment)

    assert labels(conn, [cancelled.uuid]) |> refused_to_shipments() =~ "has no label"
    assert labels(conn, [Ecto.UUID.generate()]) |> refused_to_shipments() =~ "not found"
  end

  test "a carrier's error is shown, not raised", %{conn: conn} do
    shipment = shipment!()
    StubProvider.put(%{labels: {:error, :timeout}, notify: self()})

    assert labels(conn, [shipment.uuid]) |> refused_to_shipments() ==
             "The carrier did not return the labels. Try again later."
  end
end
