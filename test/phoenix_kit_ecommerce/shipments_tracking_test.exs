defmodule PhoenixKitEcommerce.ShipmentsTrackingTest do
  @moduledoc """
  The shipments' half-hourly run (`Workers.ShipmentTrackingWorker`): the sweep
  of shipments stuck in `creating` and the tracking of the open ones
  (`Shipments.sweep_stuck/0`, `Shipments.track_shipments/1`) against the stub
  provider: the groups and their calls, the order of updates, the 60-day
  cutoff, the masked events and the shipped email the run queues.
  """

  # Changes the application env (provider registry) and the shop switch.
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment, Shipments}
  alias PhoenixKitEcommerce.Shipping.{ShipmentRef, TrackingUpdate}
  alias PhoenixKitEcommerce.Test.Shipping.{NoCancelProvider, StubProvider}
  alias PhoenixKitEcommerce.Workers.{OrderEmailWorker, ShipmentTrackingWorker}

  defmodule OtherTracker do
    @moduledoc false
    # A second carrier that tracks, without a connection of its own.
    alias PhoenixKitEcommerce.Test.Shipping.StubProvider

    def key, do: "other"
    def label, do: "Other carrier"
    defdelegate services(ctx), to: StubProvider
    defdelegate settings_fields(), to: StubProvider
    defdelegate quote(request, ctx), to: StubProvider
    defdelegate search_localities(query, ctx), to: StubProvider
    defdelegate list_pickup_points(locality, service, query, ctx), to: StubProvider
    defdelegate create_shipment(request, ctx), to: StubProvider
    defdelegate track(refs, ctx), to: StubProvider
  end

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)

    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
      StubProvider,
      OtherTracker,
      NoCancelProvider
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    StubProvider.put(%{notify: self()})
    :ok
  end

  defp track(fun), do: StubProvider.put(%{notify: self(), track: fun})

  defp shipment!(attrs) do
    order = OrderFixtures.order!(%{"status" => "paid"})
    {snapshot, attrs} = Map.pop(attrs, :context_snapshot, %{})

    Repo.insert!(
      struct(
        Shipment,
        Map.merge(
          %{
            order_uuid: order.uuid,
            provider: "stub",
            service: "branch",
            status: "created",
            tracking_number: "TRK-#{System.unique_integer([:positive])}",
            context_snapshot: Map.merge(%{"settings" => %{}, "country" => "EE"}, snapshot),
            recipient: %{"name" => "Mari Maasikas", "phone" => "+37255551234"},
            destination: %{},
            events: []
          },
          attrs
        )
      )
    )
  end

  defp reload(shipment), do: Repo.get!(Shipment, shipment.uuid)

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)

  defp report(shipment, status, opts \\ []) do
    %TrackingUpdate{
      tracking_number: shipment.tracking_number,
      status: status,
      occurred_at: opts[:at],
      description: opts[:description]
    }
  end

  defp tracked_event(at),
    do: %{"action" => "tracked", "status" => "ready_for_pickup", "occurred_at" => at}

  defp shipped_jobs(shipment) do
    worker = inspect(OrderEmailWorker)

    Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
    |> Enum.filter(&(&1.args["shipment_uuid"] == shipment.uuid))
  end

  defp connection!(environment) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("stub", "Stub #{System.unique_integer([:positive])}")

    {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "k", "environment" => environment})
    uuid
  end

  describe "the sweep" do
    test "moves only shipments stuck in creating for 10 minutes to unknown, with an event" do
      stuck = shipment!(%{status: "creating", tracking_number: nil, updated_at: ago(660)})
      waiting = shipment!(%{status: "creating", tracking_number: nil, updated_at: ago(300)})
      failed = shipment!(%{status: "failed", tracking_number: nil, updated_at: ago(3600)})
      open = shipment!(%{status: "created", updated_at: ago(3600)})

      assert Shipments.sweep_stuck() == 1

      assert %Shipment{status: "unknown", events: [%{"action" => "swept", "status" => "unknown"}]} =
               reload(stuck)

      assert %Shipment{status: "creating", events: []} = reload(waiting)
      assert reload(failed).status == "failed"
      assert reload(open).status == "created"
    end
  end

  describe "tracking" do
    test "stores a status the carrier reports, masked, with its time" do
      shipment = shipment!(%{})
      at = ~U[2026-11-20 10:00:00Z]

      track(fn _refs, _ctx ->
        {:ok, [report(shipment, :in_transit, at: at, description: "Mari Maasikas: sorted")]}
      end)

      assert %{groups: 1, failed: 0, updated: 1} = Shipments.track_shipments()

      stored = reload(shipment)
      assert stored.status == "in_transit"
      assert %DateTime{} = stored.last_tracked_at

      assert [
               %{
                 "action" => "tracked",
                 "status" => "in_transit",
                 "message" => "[redacted]: sorted",
                 "occurred_at" => "2026-11-20T10:00:00Z"
               }
             ] = stored.events
    end

    test "passes the carrier every reference of the group in one call" do
      first = shipment!(%{})
      second = shipment!(%{carrier_ref: "C-9"})

      Shipments.track_shipments()

      assert_received {:stub_called, :track, [refs]}
      refute_received {:stub_called, :track, _}

      assert Enum.sort_by(refs, & &1.tracking_number) ==
               Enum.sort_by(
                 [Shipments.shipment_ref(first), Shipments.shipment_ref(second)],
                 & &1.tracking_number
               )

      assert Enum.all?(refs, &match?(%ShipmentRef{service: "branch"}, &1))
    end

    test "matches an update by the carrier reference when the shipment has no tracking number" do
      shipment = shipment!(%{tracking_number: nil, carrier_ref: "C-77"})

      track(fn _refs, _ctx ->
        {:ok, [%TrackingUpdate{carrier_ref: "C-77", status: :ready_for_pickup}]}
      end)

      Shipments.track_shipments()

      assert reload(shipment).status == "ready_for_pickup"
    end

    test "an update about another shipment changes nothing" do
      shipment = shipment!(%{})

      track(fn _refs, _ctx ->
        {:ok, [%TrackingUpdate{tracking_number: "SOMEONE-ELSE", status: :delivered}]}
      end)

      assert %{updated: 0} = Shipments.track_shipments()
      assert reload(shipment).status == "created"
    end

    test "groups by provider, connection and environment, one call each" do
      test_env = connection!("test")
      live_env = connection!("production")

      in_test =
        shipment!(%{
          integration_uuid: test_env,
          context_snapshot: %{"settings" => %{"integration" => test_env}, "environment" => "test"}
        })

      in_live =
        shipment!(%{
          integration_uuid: live_env,
          context_snapshot: %{
            "settings" => %{"integration" => live_env},
            "environment" => "production"
          }
        })

      other = shipment!(%{provider: "other"})
      test = self()

      track(fn refs, ctx ->
        send(
          test,
          {:group, ctx.provider.key(), ctx.integration_uuid, Enum.map(refs, & &1.tracking_number)}
        )

        {:ok, []}
      end)

      assert %{groups: 3, failed: 0} = Shipments.track_shipments()

      {test_number, live_number, other_number} =
        {in_test.tracking_number, in_live.tracking_number, other.tracking_number}

      assert_received {:group, "stub", ^test_env, [^test_number]}
      assert_received {:group, "stub", ^live_env, [^live_number]}
      assert_received {:group, "other", nil, [^other_number]}
    end

    test "one failing provider does not stop another" do
      failing = shipment!(%{provider: "other"})
      working = shipment!(%{})

      track(fn _refs, ctx ->
        case ctx.provider.key() do
          "other" -> {:error, {:http_status, 503}}
          "stub" -> {:ok, [report(working, :in_transit)]}
        end
      end)

      log =
        capture_log(fn ->
          assert %{groups: 2, failed: 1, updated: 1} = Shipments.track_shipments()
        end)

      assert log =~ "other (1 shipments) failed: HTTP 503"
      assert reload(working).status == "in_transit"
      assert %Shipment{status: "created", last_tracked_at: %DateTime{}} = reload(failing)
    end

    test "a provider that crashes does not stop another" do
      crashing = shipment!(%{provider: "other"})
      working = shipment!(%{})

      track(fn _refs, ctx ->
        if ctx.provider.key() == "other",
          do: raise("carrier down"),
          else: {:ok, [report(working, :delivered)]}
      end)

      capture_log(fn -> assert %{failed: 1, updated: 1} = Shipments.track_shipments() end)

      assert reload(working).status == "delivered"
      assert reload(crashing).status == "created"
    end

    test "an update older than the last one stored is ignored, a newer one is not" do
      shipment =
        shipment!(%{status: "ready_for_pickup", events: [tracked_event("2026-11-20T12:00:00Z")]})

      track(fn _refs, _ctx ->
        {:ok, [report(shipment, :delivered, at: ~U[2026-11-20 11:00:00Z])]}
      end)

      assert %{updated: 0} = Shipments.track_shipments()
      assert reload(shipment).status == "ready_for_pickup"

      track(fn _refs, _ctx ->
        {:ok, [report(shipment, :delivered, at: ~U[2026-11-20 13:00:00Z])]}
      end)

      assert %{updated: 1} = Shipments.track_shipments()
      assert reload(shipment).status == "delivered"
    end

    test "without times an update must rank above the current status" do
      shipment = shipment!(%{status: "ready_for_pickup"})

      track(fn _refs, _ctx -> {:ok, [report(shipment, :in_transit)]} end)

      assert %{updated: 0} = Shipments.track_shipments()
      assert reload(shipment).status == "ready_for_pickup"

      track(fn _refs, _ctx -> {:ok, [report(shipment, :returned)]} end)

      assert %{updated: 1} = Shipments.track_shipments()
      assert reload(shipment).status == "returned"
    end

    test "of several updates the newest counts" do
      shipment = shipment!(%{})

      track(fn _refs, _ctx ->
        {:ok,
         [
           report(shipment, :ready_for_pickup, at: ~U[2026-11-21 09:00:00Z]),
           report(shipment, :in_transit, at: ~U[2026-11-20 09:00:00Z]),
           report(shipment, :created, at: ~U[2026-11-19 09:00:00Z])
         ]}
      end)

      Shipments.track_shipments()

      assert reload(shipment).status == "ready_for_pickup"
    end

    test "the write is conditional on the status the update was weighed against" do
      shipment = shipment!(%{})

      track(fn _refs, _ctx ->
        # The admin records the cancellation while the carrier answers.
        Repo.update_all(from(s in Shipment, where: s.uuid == ^shipment.uuid),
          set: [status: "cancelled"]
        )

        {:ok, [report(shipment, :in_transit)]}
      end)

      assert %{updated: 0} = Shipments.track_shipments()
      assert %Shipment{status: "cancelled", events: []} = reload(shipment)
    end

    test "stops 60 days after the shipment was created" do
      old = shipment!(%{inserted_at: ago(61 * 86_400)})
      young = shipment!(%{inserted_at: ago(59 * 86_400)})

      Shipments.track_shipments()

      assert_received {:stub_called, :track, [[%ShipmentRef{tracking_number: number}]]}
      assert number == young.tracking_number
      assert reload(old).last_tracked_at == nil
    end

    test "asks only open shipments of providers that track" do
      for status <- ~w(creating unknown delivered returned cancelled failed),
          do: shipment!(%{status: status})

      shipment!(%{provider: "nocancel"})

      assert %{groups: 0} = Shipments.track_shipments()
      refute_received {:stub_called, :track, _}
    end

    test "the first move on the way queues the buyer's shipped email, once" do
      shipment = shipment!(%{})

      track(fn _refs, _ctx -> {:ok, [report(shipment, :in_transit)]} end)
      Shipments.track_shipments()

      assert [%Oban.Job{args: %{"email" => "buyer_shipped"} = args}] = shipped_jobs(shipment)
      assert args["order_uuid"] == shipment.order_uuid

      track(fn _refs, _ctx -> {:ok, [report(shipment, :delivered)]} end)
      Shipments.track_shipments()

      assert reload(shipment).status == "delivered"
      assert length(shipped_jobs(shipment)) == 1
    end

    test "a move that is not on the way queues no email" do
      shipment = shipment!(%{})

      track(fn _refs, _ctx -> {:ok, [report(shipment, :cancelled)]} end)
      Shipments.track_shipments()

      assert reload(shipment).status == "cancelled"
      assert shipped_jobs(shipment) == []
    end
  end

  describe "the worker" do
    test "sweeps and tracks" do
      stuck = shipment!(%{status: "creating", tracking_number: nil, updated_at: ago(660)})
      open = shipment!(%{})
      track(fn _refs, _ctx -> {:ok, [report(open, :in_transit)]} end)

      capture_log(fn -> assert :ok = ShipmentTrackingWorker.perform(%Oban.Job{}) end)

      assert reload(stuck).status == "unknown"
      assert reload(open).status == "in_transit"
    end

    test "does nothing while the shop is off" do
      stuck = shipment!(%{status: "creating", tracking_number: nil, updated_at: ago(660)})
      open = shipment!(%{})
      track(fn _refs, _ctx -> {:ok, [report(open, :in_transit)]} end)
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

      assert :ok = ShipmentTrackingWorker.perform(%Oban.Job{})

      refute_received {:stub_called, :track, _}
      assert reload(stuck).status == "creating"
      assert reload(open).status == "created"
    end

    test "runs every 30 minutes from the module's crons" do
      assert {"7,37 * * * *", ShipmentTrackingWorker} in PhoenixKitEcommerce.oban_crons()
    end
  end
end
