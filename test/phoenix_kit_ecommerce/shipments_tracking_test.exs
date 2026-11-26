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

    test "a failing carrier is noted once on each shipment, and so is its recovery" do
      first = shipment!(%{recipient: %{"name" => "Mari Maasikas"}})
      second = shipment!(%{})

      track(fn _refs, _ctx -> {:error, {:http_status, 503, "Mari Maasikas not found"}} end)

      capture_log(fn ->
        Shipments.track_shipments()
        Shipments.track_shipments()
      end)

      for shipment <- [first, second] do
        stored = reload(shipment)

        assert [%{"action" => "tracking_failed", "status" => "created", "message" => "HTTP 503"}] =
                 stored.events

        assert %DateTime{} = Shipments.tracking_failing_since(stored)
      end

      track(fn _refs, _ctx -> {:ok, [report(first, :in_transit), report(second, :created)]} end)
      Shipments.track_shipments()

      assert [_failed, %{"action" => "tracking_resumed"}, %{"action" => "tracked"}] =
               reload(first).events

      assert [_failed, %{"action" => "tracking_resumed"}] = reload(second).events
      assert Shipments.tracking_failing_since(reload(first)) == nil
      assert Shipments.tracking_failing_since(reload(second)) == nil
    end

    test "a shipment no longer tracked is not failing, whatever its history says" do
      failed = %{
        "at" => "2026-11-21T10:00:00Z",
        "action" => "tracking_failed",
        "status" => "created"
      }

      for status <- ~w(created in_transit ready_for_pickup) do
        assert %DateTime{} =
                 Shipments.tracking_failing_since(%Shipment{status: status, events: [failed]})
      end

      for status <- ~w(delivered returned cancelled failed unknown creating) do
        assert Shipments.tracking_failing_since(%Shipment{status: status, events: [failed]}) ==
                 nil
      end
    end

    test "a group whose first shipment's context cannot be rebuilt fails without trying the rest" do
      connection = connection!("test")
      gone = Ecto.UUID.generate()

      dead =
        shipment!(%{
          integration_uuid: connection,
          inserted_at: ago(7200),
          context_snapshot: %{"settings" => %{"integration" => gone}, "environment" => "test"}
        })

      alive =
        shipment!(%{
          integration_uuid: connection,
          inserted_at: ago(3600),
          context_snapshot: %{
            "settings" => %{"integration" => connection},
            "environment" => "test"
          }
        })

      capture_log(fn -> assert %{groups: 1, failed: 1} = Shipments.track_shipments() end)

      refute_received {:stub_called, :track, _}

      for shipment <- [dead, alive] do
        assert [%{"action" => "tracking_failed", "message" => "connection_changed"}] =
                 reload(shipment).events
      end
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

    test "a higher status counts even when its time is before the last one stored" do
      # A carrier that gives the delivery a date only: it sorts before the
      # last scan of the day.
      shipment =
        shipment!(%{status: "ready_for_pickup", events: [tracked_event("2026-11-20T12:00:00Z")]})

      track(fn _refs, _ctx ->
        {:ok, [report(shipment, :delivered, at: ~U[2026-11-20 00:00:00Z])]}
      end)

      assert %{updated: 1} = Shipments.track_shipments()
      assert reload(shipment).status == "delivered"
    end

    test "of two updates of the same status the later time is stored" do
      shipment = shipment!(%{})

      track(fn _refs, _ctx ->
        {:ok,
         [
           report(shipment, :in_transit, at: ~U[2026-11-21 09:00:00Z]),
           report(shipment, :in_transit, at: ~U[2026-11-21 15:00:00Z])
         ]}
      end)

      Shipments.track_shipments()

      assert [%{"occurred_at" => "2026-11-21T15:00:00Z"}] = reload(shipment).events
    end

    test "a later-timed update of a lower status does not move it back" do
      shipment =
        shipment!(%{status: "ready_for_pickup", events: [tracked_event("2026-11-20T12:00:00Z")]})

      track(fn _refs, _ctx ->
        {:ok, [report(shipment, :created, at: ~U[2026-11-21 08:00:00Z])]}
      end)

      assert %{updated: 0} = Shipments.track_shipments()
      assert reload(shipment).status == "ready_for_pickup"
    end

    test "an untimed higher status is not dropped because a timed one came with it" do
      shipment = shipment!(%{status: "in_transit"})

      track(fn _refs, _ctx ->
        {:ok,
         [
           report(shipment, :delivered),
           report(shipment, :in_transit, at: ~U[2026-11-21 07:00:00Z])
         ]}
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

    test "a shipment the answer says nothing about has no news: it is stamped, and the count logged" do
      answered = shipment!(%{})
      silent = shipment!(%{})

      track(fn _refs, _ctx -> {:ok, [report(answered, :in_transit)]} end)

      # The count is an info line; the suite logs warnings and up.
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      log = capture_log(fn -> assert %{updated: 1} = Shipments.track_shipments() end)

      assert log =~ "stub answered for 1 of 2 shipments"
      refute log =~ silent.tracking_number

      assert %Shipment{status: "created", last_tracked_at: %DateTime{}, events: []} =
               reload(silent)

      assert reload(answered).status == "in_transit"
    end

    test "asks at most 1000 shipments a run, those asked longest ago first" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      orders =
        for n <- 1..1002 do
          %{
            uuid: Ecto.UUID.generate(),
            order_number: "CAP-#{System.unique_integer([:positive])}-#{n}",
            status: "paid",
            total: Decimal.new("1"),
            inserted_at: now,
            updated_at: now
          }
        end

      Repo.insert_all(PhoenixKitBilling.Order, orders)

      # The first two were asked a minute and an hour ago, the rest never.
      tracked_at = fn
        1 -> ago(60)
        2 -> ago(3600)
        _n -> nil
      end

      rows =
        orders
        |> Enum.with_index(1)
        |> Enum.map(fn {order, n} ->
          %{
            uuid: Ecto.UUID.generate(),
            order_uuid: order.uuid,
            provider: "stub",
            service: "branch",
            status: "created",
            tracking_number: "CAP-#{n}",
            context_snapshot: %{"settings" => %{}, "country" => "EE"},
            parcels: [],
            recipient: %{},
            destination: %{},
            extra: %{},
            events: [],
            last_tracked_at: tracked_at.(n),
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(Shipment, rows)

      Shipments.track_shipments()

      assert_received {:stub_called, :track, [refs]}
      numbers = MapSet.new(refs, & &1.tracking_number)

      assert MapSet.size(numbers) == 1000
      refute MapSet.member?(numbers, "CAP-1")
      refute MapSet.member?(numbers, "CAP-2")
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

    test "a shipped email that cannot be queued leaves the status, and the rest of the group" do
      refused = shipment!(%{inserted_at: ago(7200)})
      stored = shipment!(%{inserted_at: ago(3600)})

      track(fn _refs, _ctx ->
        {:ok, [report(refused, :in_transit), report(stored, :cancelled)]}
      end)

      # The e-mail job's unique check is refused, as a mail queue that is down.
      Process.put(:test_repo_refuse_source, "oban_jobs")

      log =
        try do
          capture_log(fn -> assert %{updated: 1} = Shipments.track_shipments() end)
        after
          Process.delete(:test_repo_refuse_source)
        end

      assert log =~ "Shipment #{refused.uuid}: storing its tracking raised"
      assert %Shipment{status: "created", events: []} = reload(refused)
      assert shipped_jobs(refused) == []
      assert reload(stored).status == "cancelled"
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
