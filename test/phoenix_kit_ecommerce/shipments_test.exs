defmodule PhoenixKitEcommerce.ShipmentsTest do
  @moduledoc """
  Registering the shipment of a paid order (`PhoenixKitEcommerce.Shipments`)
  against the stub provider: the checks before anything is written, the
  request the carrier gets, the outcome rule, the compare-and-set retry, the
  admin's resolutions, the rebuilt context and the masking of what is stored.
  The concurrent insert is in `ShipmentsRaceTest`.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{OrderFixtures, Shipment, Shipments}

  alias PhoenixKitEcommerce.Shipping.{
    Address,
    Destination,
    Locality,
    Parcel,
    ShipmentRef,
    ShipmentRequest,
    ShipmentResult
  }

  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @locality %Locality{id: "L1", name: "Tallinn", country: "EE"}
  @settings %{"sender_city" => %{"id" => "c1", "name" => "Tallinn"}}

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    # Started by `PhoenixKitEcommerce.children/0` in a host.
    start_supervised!({Task.Supervisor, name: PhoenixKitEcommerce.Shipments.TaskSupervisor})

    stub(%{})
    :ok
  end

  # The stub's behaviour, with the order's pickup point listed by default.
  # The carrier is called from the attempt's own process, so the stub reports
  # to the test process by pid.
  defp stub(config),
    do: StubProvider.put(Map.merge(%{points: [StubProvider.point("P1")], notify: self()}, config))

  defp method!(provider \\ "stub", service \\ "branch", settings \\ @settings) do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => "4.00",
        "active" => true,
        "shipping_provider" => %{
          "provider" => provider,
          "service" => service,
          "settings" => settings
        }
      })

    method
  end

  defp branch, do: %Destination{locality: @locality, pickup_point: StubProvider.point("P1")}

  defp paid_order!(method, opts \\ []) do
    service = Keyword.get(opts, :service, "branch")

    OrderFixtures.order!(%{
      "status" => Keyword.get(opts, :status, "paid"),
      "currency" => "EUR",
      "subtotal" => Decimal.new("49.90"),
      "total" => Decimal.new("53.89"),
      "billing_snapshot" =>
        Keyword.get(opts, :billing, %{
          "type" => "individual",
          "first_name" => "Mari",
          "last_name" => "Maasikas",
          "email" => "mari@example.com",
          "phone" => "5555 1234",
          "country" => "EE",
          "city" => "Tallinn",
          "address_line1" => "Pikk 1"
        }),
      "line_items" => [
        %{
          "name" => "Vase",
          "quantity" => 2,
          "unit_price" => "20.00",
          "total" => "40.00",
          "type" => "product"
        },
        %{
          "name" => "Lamp",
          "quantity" => 1,
          "unit_price" => "9.90",
          "total" => "9.90",
          "type" => "product"
        },
        OrderFixtures.shipping_line("3.99")
      ],
      "metadata" => %{
        "shipping_method_uuid" => method.uuid,
        "shipping_country" => "EE",
        "shipping_provider" => %{
          "provider" => Keyword.get(opts, :provider, "stub"),
          "service" => service
        },
        "shipping_destination" => Destination.to_map(Keyword.get(opts, :destination, branch())),
        "shipping_parcels" => [Parcel.to_map(%Parcel{weight_g: 1200})],
        "shipping_pay_on_delivery" => Keyword.get(opts, :pay_on_delivery, false)
      }
    })
  end

  defp rows(order), do: Repo.all(from(s in Shipment, where: s.order_uuid == ^order.uuid))

  defp set_order!(order, changes),
    do: Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: changes)

  defp set!(shipment, changes) do
    Repo.update_all(from(s in Shipment, where: s.uuid == ^shipment.uuid), set: changes)
    Shipments.get_shipment(shipment.uuid)
  end

  defp unknown!(order) do
    stub(%{create: {:error, :timeout}})
    {:ok, shipment} = capture_log_result(fn -> Shipments.register(order) end)
    assert shipment.status == "unknown"
    stub(%{})
    shipment
  end

  defp capture_log_result(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end

  describe "register/2" do
    test "registers the shipment of a paid order and stores the carrier's answer" do
      method = method!()
      order = paid_order!(method)
      actor = Ecto.UUID.generate()

      stub(%{
        create: %ShipmentResult{
          carrier_ref: "C-77",
          tracking_number: "CE123EE",
          tracking_url: "https://track.example/CE123EE",
          carrier_label: "Omniva",
          extra: %{"sender" => %{"phone" => "+3725000000"}}
        }
      })

      assert {:ok, %Shipment{} = shipment} = Shipments.register(order, actor_uuid: actor)

      assert %{
               status: "created",
               order_uuid: order_uuid,
               method_uuid: method_uuid,
               provider: "stub",
               service: "branch",
               carrier_ref: "C-77",
               tracking_number: "CE123EE",
               tracking_url: "https://track.example/CE123EE",
               carrier_label: "Omniva",
               extra: %{"sender" => %{"phone" => "+3725000000"}},
               error: nil,
               created_by_uuid: ^actor
             } = shipment

      assert order_uuid == order.uuid
      assert method_uuid == method.uuid

      assert [
               %{"action" => "register", "status" => "creating", "actor_uuid" => ^actor},
               %{"action" => "submit", "status" => "creating", "actor_uuid" => ^actor},
               %{"action" => "result", "status" => "created"}
             ] = shipment.events

      assert [_one] = rows(order)
    end

    test "sends the order's number, recipient, goods and destination" do
      order = paid_order!(method!())

      assert {:ok, _shipment} = Shipments.register(order)
      assert_received {:stub_called, :create_shipment, [%ShipmentRequest{} = request]}

      assert request.order_uuid == order.uuid
      assert request.reference == order.order_number
      assert request.service == "branch"
      assert request.country == "EE"
      assert request.destination == branch()
      assert request.parcels == [%Parcel{weight_g: 1200}]

      assert request.recipient == %{
               name: "Mari Maasikas",
               company: nil,
               email: "mari@example.com",
               phone: "+37255551234",
               raw_phone: "5555 1234"
             }

      claimed = Shipments.get_shipment(request.idempotency_key |> String.split(":") |> hd())

      assert request.idempotency_key ==
               "#{claimed.uuid}:#{DateTime.to_unix(claimed.submitted_at, :microsecond)}"

      assert request.payer == :shop
      assert request.description == "Vase x2, Lamp"
      assert Decimal.equal?(request.declared_value, "49.90")
      assert request.currency == "EUR"
      assert request.cod_amount == nil
      assert request.cod_currency == nil
    end

    test "a pay-on-delivery order is paid by the recipient, a company keeps its contact person" do
      billing = %{
        "type" => "company",
        "company_name" => "Kask OÜ",
        "email" => "kask@example.com",
        "first_name" => "Mari",
        "last_name" => "Maasikas",
        "phone" => "+371 6123 4567",
        "country" => "EE"
      }

      order = paid_order!(method!(), pay_on_delivery: true, billing: billing)

      assert {:ok, _shipment} = Shipments.register(order)
      assert_received {:stub_called, :create_shipment, [request]}

      assert request.payer == :recipient

      assert request.recipient == %{
               name: "Mari Maasikas",
               company: "Kask OÜ",
               email: "kask@example.com",
               phone: "+37161234567",
               raw_phone: "+371 6123 4567"
             }
    end

    test "the admin's corrections are what is stored and sent" do
      order = paid_order!(method!())
      other = %Destination{locality: @locality, pickup_point: StubProvider.point("P2")}
      stub(%{points: [StubProvider.point("P1"), StubProvider.point("P2")]})

      assert {:ok, shipment} =
               Shipments.register(order,
                 parcels: [%Parcel{weight_g: 3000, length_mm: 300, width_mm: 200, height_mm: 100}],
                 recipient: %{"name" => "Jaan Tamm", "phone" => "5123 4567"},
                 destination: other
               )

      assert shipment.recipient == %{
               "name" => "Jaan Tamm",
               "company" => nil,
               "email" => nil,
               "phone" => "+37251234567",
               "raw_phone" => "5123 4567"
             }

      assert [%{"weight_g" => 3000}] = shipment.parcels
      assert %{"pickup_point" => %{"id" => "P2"}} = shipment.destination

      assert_received {:stub_called, :create_shipment, [request]}
      assert request.destination.pickup_point.id == "P2"
      assert request.recipient.name == "Jaan Tamm"
    end
  end

  describe "begin_shipment/2 refuses before it writes" do
    test "an order that is not paid" do
      order = paid_order!(method!(), status: "confirmed")
      flush_stub_calls()

      assert {:error, :order_not_paid} = Shipments.begin_shipment(order)
      assert rows(order) == []
      refute_received {:stub_called, _, _}
    end

    test "a provider that cannot register shipments, before anything is written" do
      method = method!("table", "default", %{"rates" => "10 5", "destination" => "pickup_point"})
      order = paid_order!(method, provider: "table", service: "default")

      assert {:error, :shipments_not_supported} = Shipments.begin_shipment(order)
      assert rows(order) == []
    end

    test "an order whose method is gone, or now uses another provider" do
      method = method!()

      gone = paid_order!(method)

      set_order!(gone,
        metadata: Map.put(gone.metadata, "shipping_method_uuid", Ecto.UUID.generate())
      )

      assert {:error, :no_shipping_method} = Shipments.begin_shipment(gone.uuid)

      switched = paid_order!(method, provider: "omniva")
      assert {:error, :provider_changed} = Shipments.begin_shipment(switched)

      assert rows(gone) == [] and rows(switched) == []
    end

    test "a pickup point the provider no longer lists, asked fresh rather than cached" do
      order = paid_order!(method!())
      stub(%{points: [StubProvider.point("P9")]})

      assert {:error, :pickup_point_unavailable} = Shipments.begin_shipment(order)
      assert rows(order) == []
    end

    test "a point that cannot be checked right now" do
      order = paid_order!(method!())
      stub(%{points: {:error, :timeout}})

      capture_log(fn ->
        assert {:error, {:destination_unverified, :timeout}} = Shipments.begin_shipment(order)
      end)

      assert rows(order) == []
    end

    test "a destination the service cannot use" do
      order = paid_order!(method!(), destination: %Destination{locality: @locality})

      assert {:error, :invalid_destination} = Shipments.begin_shipment(order)
      assert rows(order) == []
    end

    test "a second live shipment of the same order" do
      order = paid_order!(method!())

      assert {:ok, %Shipment{status: "creating"}} = Shipments.begin_shipment(order)
      assert {:error, :live_shipment_exists} = Shipments.begin_shipment(order)
      assert [_one] = rows(order)
    end
  end

  describe "the outcome of the carrier call" do
    test "a timeout leaves the shipment unknown" do
      order = paid_order!(method!())
      stub(%{modes: %{create_shipment: :hang}})

      capture_log(fn ->
        assert {:ok, %Shipment{status: "unknown", error: "timeout"}} =
                 Shipments.register(order, context_opts: [timeout: 100])
      end)
    end

    test "a definite failure is failed, anything else is unknown" do
      method = method!()

      cases = [
        {{:rejected, "Phone is missing"}, "failed", "Phone is missing"},
        {{:http_status, 422, "bad postcode"}, "failed", "HTTP 422: bad postcode"},
        {{:http_status, 429}, "failed", "HTTP 429"},
        {:econnrefused, "failed", "econnrefused"},
        {%Req.TransportError{reason: :econnrefused}, "failed", "connection refused"},
        {{:http_status, 409}, "unknown", "HTTP 409"},
        {{:http_status, 503, "busy"}, "unknown", "HTTP 503: busy"},
        {%Req.TransportError{reason: :closed}, "unknown", "socket closed"},
        {{:provider_crashed, "boom"}, "unknown", "crashed: boom"}
      ]

      for {reason, status, error} <- cases do
        order = paid_order!(method)
        stub(%{create: {:error, reason}})

        capture_log(fn ->
          assert {:ok, %Shipment{status: ^status, error: ^error}} = Shipments.register(order),
                 "#{inspect(reason)} should be #{status}"
        end)
      end
    end

    test "an unreadable answer is unknown" do
      order = paid_order!(method!())
      stub(%{create: %ShipmentResult{}})

      capture_log(fn ->
        assert {:ok, %Shipment{status: "unknown", error: "unexpected answer: " <> _}} =
                 Shipments.register(order)
      end)
    end

    test "two submits of one shipment call the carrier once" do
      order = paid_order!(method!())
      test_pid = self()

      stub(%{
        create: fn _request, _ctx ->
          send(test_pid, {:carrier_called, self()})

          receive do
            :answer -> {:ok, %ShipmentResult{tracking_number: "ONCE-1"}}
          end
        end
      })

      {:ok, shipment} = Shipments.begin_shipment(order)
      first = Task.async(fn -> Shipments.submit_shipment(shipment) end)
      assert_receive {:carrier_called, carrier}, 5_000

      second = Task.async(fn -> Shipments.submit_shipment(shipment) end)
      assert {:ok, {:error, :shipment_changed}} = Task.yield(second, 5_000)
      refute_received {:carrier_called, _}

      send(carrier, :answer)

      assert {:ok, %Shipment{status: "created", tracking_number: "ONCE-1"}} =
               Task.await(first, 10_000)
    end

    test "the answer is stored even when the caller is gone" do
      order = paid_order!(method!())
      test_pid = self()

      stub(%{
        create: fn _request, _ctx ->
          send(test_pid, {:carrier_called, self(), Process.get(:"$callers")})

          receive do
            :answer -> {:ok, %ShipmentResult{tracking_number: "ORPHAN-1"}}
          end
        end
      })

      {:ok, shipment} = Shipments.begin_shipment(order)

      # A LiveView's start_async: the caller dies with the page.
      page = spawn(fn -> receive do: (:never -> :ok) end)

      {:ok, caller} =
        Task.start(fn ->
          Process.link(page)
          Shipments.submit_shipment(shipment)
        end)

      # The answer is logged at info, before it is written.
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)

      caller_ref = Process.monitor(caller)
      assert_receive {:carrier_called, carrier, [attempt | _]}, 5_000
      attempt_ref = Process.monitor(attempt)

      Process.exit(page, {:shutdown, :closed})
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 5_000

      log =
        capture_log(fn ->
          send(carrier, :answer)
          assert_receive {:DOWN, ^attempt_ref, :process, ^attempt, _}, 10_000
        end)

      assert log =~ "ORPHAN-1"

      assert %Shipment{status: "created", tracking_number: "ORPHAN-1"} =
               Shipments.get_shipment(shipment.uuid)
    end

    test "an order no longer paid is not sent, and the shipment fails" do
      order = paid_order!(method!())
      {:ok, shipment} = Shipments.begin_shipment(order)
      set_order!(order, status: "refunded")
      flush_stub_calls()

      assert {:ok, %Shipment{status: "failed", error: "order_not_paid"}} =
               Shipments.submit_shipment(shipment)

      refute_received {:stub_called, :create_shipment, _}
    end

    test "a provider that turns out not to support create sent nothing: failed" do
      order = paid_order!(method!())
      stub(%{create: {:error, :not_supported}})

      capture_log(fn ->
        assert {:ok, %Shipment{status: "failed", error: "not_supported"}} =
                 Shipments.register(order)
      end)
    end

    test "an answer after the shipment left creating changes nothing" do
      order = paid_order!(method!())
      test_pid = self()

      stub(%{
        create: fn _request, _ctx ->
          send(test_pid, {:carrier_called, self()})

          receive do
            :answer -> {:ok, %ShipmentResult{tracking_number: "LATE-1"}}
          end
        end
      })

      {:ok, shipment} = Shipments.begin_shipment(order)
      task = Task.async(fn -> Shipments.submit_shipment(shipment) end)
      assert_receive {:carrier_called, carrier}, 5_000

      # What the tracking run's sweep does to a shipment stuck in creating.
      set!(shipment, status: "unknown")
      send(carrier, :answer)

      log = capture_log(fn -> assert {:error, :shipment_changed} = Task.await(task, 10_000) end)
      assert log =~ "LATE-1"

      assert %Shipment{status: "unknown", tracking_number: nil} =
               Shipments.get_shipment(shipment.uuid)
    end

    test "a shipment that is not creating is not sent" do
      order = paid_order!(method!())
      {:ok, created} = Shipments.register(order)
      flush_stub_calls()

      assert {:error, :shipment_changed} = Shipments.submit_shipment(created)
      refute_received {:stub_called, :create_shipment, _}
    end

    test "a connection whose environment changed is not called, and the shipment failed" do
      order = paid_order!(method!())
      connection = Ecto.UUID.generate()

      {:ok, shipment} =
        Shipments.begin_shipment(order,
          context_opts: [credentials: %{"environment" => "sandbox"}, integration_uuid: connection]
        )

      assert shipment.integration_uuid == connection
      assert shipment.context_snapshot["environment"] == "sandbox"
      assert shipment.context_snapshot["settings"]["integration"] == connection

      assert {:ok, %Shipment{status: "failed", error: "connection_environment_changed"}} =
               Shipments.submit_shipment(shipment,
                 context_opts: [credentials: %{"environment" => "production"}]
               )

      refute_received {:stub_called, :create_shipment, _}
    end
  end

  describe "retry_shipment/2" do
    test "is a compare-and-set failed -> creating on the same row, with the corrections" do
      order = paid_order!(method!())
      stub(%{create: {:error, {:rejected, "Phone is missing"}}})
      {:ok, failed} = capture_log_result(fn -> Shipments.register(order) end)
      assert failed.status == "failed"

      stub(%{create: %ShipmentResult{tracking_number: "OK-2"}})

      assert {:ok, again} =
               Shipments.retry_shipment(failed,
                 recipient: %{"name" => "Mari", "phone" => "+37255550000"}
               )

      assert again.uuid == failed.uuid
      assert again.status == "creating"
      assert again.error == nil
      assert again.recipient["phone"] == "+37255550000"
      assert List.last(again.events)["action"] == "retry"

      assert {:ok, %Shipment{status: "created", tracking_number: "OK-2"}} =
               Shipments.submit_shipment(again)

      # Each attempt has its own idempotency key.
      keys =
        for {:stub_called, :create_shipment, [request]} <- flush_messages(),
            do: request.idempotency_key

      assert [first_key, second_key] = keys
      assert String.starts_with?(first_key, failed.uuid <> ":")
      refute first_key == second_key

      assert [_one] = rows(order)
      assert {:error, :shipment_changed} = Shipments.retry_shipment(again)
    end

    test "keeps what was sent last time unless corrected" do
      order = paid_order!(method!())
      stub(%{create: {:error, {:rejected, "No"}}})

      {:ok, failed} =
        capture_log_result(fn ->
          Shipments.register(order,
            recipient: %{"name" => "Fixed Name", "phone" => "+37255551111"}
          )
        end)

      assert {:ok, again} = Shipments.retry_shipment(failed)
      assert again.recipient["name"] == "Fixed Name"
    end

    test "a conflict with another live shipment is reported, not raised" do
      order = paid_order!(method!())
      stub(%{create: {:error, {:rejected, "No"}}})
      {:ok, failed} = capture_log_result(fn -> Shipments.register(order) end)

      stub(%{})
      assert {:ok, %Shipment{status: "creating"}} = Shipments.begin_shipment(order)

      assert {:error, :live_shipment_exists} = Shipments.retry_shipment(failed)
      assert %Shipment{status: "failed"} = Shipments.get_shipment(failed.uuid)
    end

    test "an order no longer paid is not retried" do
      order = paid_order!(method!())
      stub(%{create: {:error, {:rejected, "No"}}})
      {:ok, failed} = capture_log_result(fn -> Shipments.register(order) end)

      set_order!(order, status: "refunded")

      assert {:error, :order_not_paid} = Shipments.retry_shipment(failed)
      assert %Shipment{status: "failed"} = Shipments.get_shipment(failed.uuid)
    end
  end

  describe "the admin's resolutions" do
    test "an unknown shipment is marked failed, or given its tracking number" do
      method = method!()
      actor = Ecto.UUID.generate()

      one = unknown!(paid_order!(method))

      assert {:ok, %Shipment{status: "failed"} = failed} =
               Shipments.mark_failed(one, actor_uuid: actor)

      assert %{"action" => "mark_failed", "actor_uuid" => ^actor} = List.last(failed.events)

      two = unknown!(paid_order!(method))

      assert {:error, :tracking_number_required} = Shipments.enter_tracking_number(two, "  ")

      assert {:ok,
              %Shipment{
                status: "created",
                tracking_number: "CE9EE",
                tracking_url: "https://t/CE9EE"
              }} =
               Shipments.enter_tracking_number(two, " CE9EE ", tracking_url: "https://t/CE9EE")
    end

    test "only an unknown shipment, or one stuck in creating for 10 minutes, is resolved" do
      method = method!()
      {:ok, created} = Shipments.register(paid_order!(method))

      assert {:error, :shipment_changed} = Shipments.mark_failed(created)
      assert {:error, :shipment_changed} = Shipments.enter_tracking_number(created, "X")

      {:ok, creating} = Shipments.begin_shipment(paid_order!(method))
      assert {:error, :shipment_changed} = Shipments.mark_failed(creating)

      eleven_minutes_ago =
        DateTime.utc_now() |> DateTime.add(-11, :minute) |> DateTime.truncate(:second)

      stuck = set!(creating, updated_at: eleven_minutes_ago)
      assert {:ok, %Shipment{status: "failed"}} = Shipments.mark_failed(stuck)
    end

    test "cancelled at the carrier is recorded locally, for any provider" do
      {:ok, created} = Shipments.register(paid_order!(method!()))
      flush_stub_calls()

      assert {:ok, %Shipment{status: "cancelled"} = cancelled} =
               Shipments.mark_cancelled_at_carrier(created)

      assert List.last(cancelled.events)["action"] == "cancelled_at_carrier"
      refute_received {:stub_called, :cancel_shipment, _}
      assert {:error, :shipment_changed} = Shipments.mark_cancelled_at_carrier(cancelled)
    end

    test "cancel asks the carrier first, and a refusal writes nothing" do
      method = method!()
      {:ok, created} = Shipments.register(paid_order!(method))

      stub(%{cancel: {:error, :too_late}})

      capture_log(fn ->
        assert {:error, :too_late} = Shipments.cancel_shipment(created)
      end)

      assert %Shipment{status: "created"} = Shipments.get_shipment(created.uuid)

      stub(%{})
      assert {:ok, %Shipment{status: "cancelled"}} = Shipments.cancel_shipment(created)

      assert_received {:stub_called, :cancel_shipment,
                       [
                         %ShipmentRef{
                           carrier_ref: "C-1",
                           tracking_number: "TRK-1",
                           service: "branch"
                         }
                       ]}

      assert {:error, :shipment_changed} = Shipments.cancel_shipment(created)
    end

    test "an event written while the carrier is called is kept" do
      order = paid_order!(method!())
      test_pid = self()

      stub(%{
        create: fn _request, _ctx ->
          send(test_pid, {:carrier_called, self()})

          receive do
            :answer -> {:ok, %ShipmentResult{tracking_number: "KEEP-1"}}
          end
        end
      })

      {:ok, shipment} = Shipments.begin_shipment(order)
      task = Task.async(fn -> Shipments.submit_shipment(shipment) end)
      assert_receive {:carrier_called, carrier}, 5_000

      # Another writer appends an event meanwhile.
      Repo.query!(
        "UPDATE phoenix_kit_shop_shipments SET events = events || $1::text::jsonb WHERE uuid = $2",
        [~s([{"action": "other"}]), Ecto.UUID.dump!(shipment.uuid)]
      )

      send(carrier, :answer)
      assert {:ok, %Shipment{status: "created"} = created} = Task.await(task, 10_000)

      assert Enum.map(created.events, & &1["action"]) == ["register", "submit", "other", "result"]
    end

    test "events keep the last 50" do
      shipment = unknown!(paid_order!(method!()))
      old = for n <- 1..50, do: %{"action" => "old-#{n}"}
      shipment = set!(shipment, events: old)

      {:ok, failed} = Shipments.mark_failed(shipment)

      assert length(failed.events) == 50
      assert hd(failed.events)["action"] == "old-2"
      assert List.last(failed.events)["action"] == "mark_failed"
    end
  end

  describe "shipment_context/2" do
    test "is rebuilt from the snapshot and refuses another connection or environment" do
      order = paid_order!(method!())
      connection = Ecto.UUID.generate()
      sandbox = %{"environment" => "sandbox"}

      {:ok, shipment} =
        Shipments.register(order,
          context_opts: [credentials: sandbox, integration_uuid: connection]
        )

      assert {:ok, ctx} =
               Shipments.shipment_context(shipment, context_opts: [credentials: sandbox])

      assert ctx.integration_uuid == connection
      assert ctx.service == "branch"
      assert ctx.country == "EE"
      assert ctx.currency == "EUR"

      assert {:error, :connection_environment_changed} =
               Shipments.shipment_context(shipment,
                 context_opts: [credentials: %{"environment" => "production"}]
               )

      assert {:error, :connection_changed} =
               Shipments.shipment_context(shipment,
                 context_opts: [credentials: sandbox, integration_uuid: Ecto.UUID.generate()]
               )
    end
  end

  describe "masking" do
    test "the recipient's data in the carrier's text is masked before it is stored" do
      method = method!("stub", "courier")

      home = %Destination{
        locality: @locality,
        address: %Address{street: "Pikk tänav", house: "12a"}
      }

      order = paid_order!(method, service: "courier", destination: home)

      message =
        "Recipient Mari Maasikas (+372 5555 1234 / 55551234 / mari@example.com) at Pikk tänav 12a: " <>
          "MAASIKAS unknown; write to ops@carrier.example or call +372 600 0000. " <>
          String.duplicate("x", 400)

      stub(%{create: {:error, {:rejected, message}}})
      {:ok, failed} = capture_log_result(fn -> Shipments.register(order) end)

      assert String.length(failed.error) == 300

      for secret <- ~w(Mari Maasikas MAASIKAS 55551234 mari@example.com Pikk 12a ops@carrier 600) do
        refute failed.error =~ secret, "#{secret} survived: #{failed.error}"
        refute List.last(failed.events)["message"] =~ secret
      end

      assert failed.error =~ "[redacted]"
      assert failed.error =~ "[email]"
      assert failed.error =~ "[phone]"
      assert failed.error =~ "unknown; write to"
    end
  end

  defp flush_messages(acc \\ []) do
    receive do
      message -> flush_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp flush_stub_calls do
    receive do
      {:stub_called, _, _} -> flush_stub_calls()
    after
      0 -> :ok
    end
  end
end
