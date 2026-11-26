defmodule PhoenixKitEcommerce.Shipping.ShipmentFacadeTest do
  @moduledoc """
  The facade's shipment calls (`create_shipment/2`, `cancel_shipment/2`,
  `print_labels/3`, `track/2`): the export check, isolation, the create
  timeout, the answer checks, no cache, telemetry and shape-only logging, and
  the failure rule `definite_failure?/1`.
  """

  # Changes application env, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce.Shipping

  alias PhoenixKitEcommerce.Shipping.{
    LabelOptions,
    ShipmentRef,
    ShipmentRequest,
    ShipmentResult,
    TrackingUpdate
  }

  alias PhoenixKitEcommerce.Shipping.Providers.{Fixed, Table}
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers) end)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])
    :ok
  end

  defp method(provider \\ "stub") do
    %ShippingMethod{
      uuid: "00000000-0000-0000-0000-000000000001",
      price: Decimal.new("5"),
      currency: "EUR",
      metadata: %{"shipping_provider" => %{"provider" => provider, "service" => "branch"}}
    }
  end

  defp ctx(stub \\ %{}, opts \\ []) do
    Shipping.context(
      method(),
      [credentials: nil, stub: Map.put_new(stub, :notify, self())] ++ opts
    )
  end

  defp request, do: %ShipmentRequest{order_uuid: "o-1", reference: "ORD-1", service: "branch"}
  defp ref, do: %ShipmentRef{carrier_ref: "C-1", tracking_number: "TRK-1", service: "branch"}

  describe "supports?/2" do
    test "names the optional shipment callbacks a provider exports" do
      for operation <- [:create_shipment, :cancel_shipment, :print_labels, :track] do
        assert Shipping.supports?(StubProvider, operation)
        assert Shipping.supports?(ctx(), operation)
        refute Shipping.supports?(Fixed, operation)
        refute Shipping.supports?(Table, operation)
      end

      refute Shipping.supports?(StubProvider, :quote)
      refute Shipping.supports?(nil, :create_shipment)
      refute Shipping.supports?(Shipping.context(method("nope")), :create_shipment)
    end
  end

  describe "create_shipment/2" do
    test "returns the carrier's result" do
      result = %ShipmentResult{tracking_number: "T-9", carrier_label: "Omniva"}

      assert {:ok, ^result} = Shipping.create_shipment(ctx(%{create: result}), request())
      assert_received {:stub_called, :create_shipment, [%ShipmentRequest{reference: "ORD-1"}]}
    end

    test "is never cached" do
      context = ctx()

      assert {:ok, _} = Shipping.create_shipment(context, request())
      assert {:ok, _} = Shipping.create_shipment(context, request())

      assert_received {:stub_called, :create_shipment, _}
      assert_received {:stub_called, :create_shipment, _}
    end

    test "a provider without the callback is not called" do
      assert {:error, :not_supported} =
               Shipping.create_shipment(Shipping.context(method("fixed")), request())

      assert {:error, :unknown_provider} =
               Shipping.create_shipment(Shipping.context(method("nope")), request())
    end

    test "a result with neither a carrier reference nor a tracking number is a bad return" do
      capture_log(fn ->
        assert {:error, {:bad_return, _}} =
                 Shipping.create_shipment(ctx(%{create: %ShipmentResult{}}), request())

        assert {:error, {:bad_return, _}} =
                 Shipping.create_shipment(ctx(%{mode: :bad_return}), request())
      end)
    end

    test "a crash is an error, not a raise" do
      capture_log(fn ->
        assert {:error, {:provider_crashed, _}} =
                 Shipping.create_shipment(ctx(%{mode: :crash}), request())
      end)
    end

    test "waits ctx.opts[:timeout], and its own 30 seconds otherwise" do
      capture_log(fn ->
        assert {:error, :timeout} =
                 Shipping.create_shipment(ctx(%{mode: :hang}, timeout: 50), request())
      end)

      parent = self()

      create = fn _request, ctx ->
        send(parent, {:timeout_seen, ctx.opts[:timeout]})
        {:ok, %ShipmentResult{tracking_number: "T"}}
      end

      assert {:ok, _} = Shipping.create_shipment(ctx(%{create: create}), request())
      assert_received {:timeout_seen, 30_000}
    end

    test "logs the shape of an error, never its text" do
      rejected = {:rejected, "Phone +37255551234 of Mari Maasikas is invalid"}

      log =
        capture_log(fn ->
          assert {:error, ^rejected} =
                   Shipping.create_shipment(ctx(%{create: {:error, rejected}}), request())
        end)

      assert log =~ "create_shipment failed: {:rejected, ...}"
      refute log =~ "Maasikas"
      refute log =~ "37255551234"
    end

    test "emits telemetry with the operation" do
      ref = make_ref()
      test_pid = self()
      handler = "shipment-test-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:phoenix_kit_ecommerce, :shipping, :provider, :stop],
        fn _event, _measurements, metadata, _config -> send(test_pid, {ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _} = Shipping.create_shipment(ctx(), request())
      assert_receive {^ref, %{provider: "stub", operation: :create_shipment, status: :ok}}
    end
  end

  describe "cancel_shipment/2" do
    test ":ok, an error as it is, and a bad return" do
      assert :ok = Shipping.cancel_shipment(ctx(), ref())
      assert_received {:stub_called, :cancel_shipment, [%ShipmentRef{carrier_ref: "C-1"}]}

      capture_log(fn ->
        assert {:error, :too_late} =
                 Shipping.cancel_shipment(ctx(%{cancel: {:error, :too_late}}), ref())

        assert {:error, {:bad_return, _}} =
                 Shipping.cancel_shipment(ctx(%{cancel: :yes}), ref())
      end)

      assert {:error, :not_supported} =
               Shipping.cancel_shipment(Shipping.context(method("fixed")), ref())
    end
  end

  describe "print_labels/3" do
    test "returns the document, refuses any other shape" do
      assert {:ok, %{content_type: "application/pdf", body: "%PDF-stub"}} =
               Shipping.print_labels(ctx(), [ref()], %LabelOptions{format: :a6})

      assert_received {:stub_called, :print_labels,
                       [[%ShipmentRef{}], %LabelOptions{format: :a6}]}

      capture_log(fn ->
        assert {:error, {:bad_return, _}} =
                 Shipping.print_labels(ctx(%{labels: {:ok, "pdf"}}), [ref()], %LabelOptions{})
      end)
    end
  end

  describe "track/2" do
    test "returns the updates; an empty list does not call the provider" do
      update = %TrackingUpdate{tracking_number: "TRK-1", status: :in_transit}

      assert {:ok, [^update]} = Shipping.track(ctx(%{track: {:ok, [update]}}), [ref()])
      assert_received {:stub_called, :track, [[%ShipmentRef{}]]}

      assert {:ok, []} = Shipping.track(ctx(), [])
      refute_received {:stub_called, :track, _}

      capture_log(fn ->
        assert {:error, {:bad_return, _}} =
                 Shipping.track(ctx(%{track: {:ok, [%{status: "x"}]}}), [ref()])
      end)
    end
  end

  describe "definite_failure?/1" do
    test "the carrier certainly does not have the shipment" do
      for status <- [400, 401, 403, 404, 422, 429] do
        assert Shipping.definite_failure?({:http_status, status})
        assert Shipping.definite_failure?({:http_status, status, %{"error" => "x"}})
      end

      assert Shipping.definite_failure?({:rejected, "Phone is missing"})
      assert Shipping.definite_failure?(:econnrefused)
      assert Shipping.definite_failure?(%Req.TransportError{reason: :econnrefused})
    end

    test "anything else leaves it unknown" do
      for status <- [408, 409, 500, 502, 503, 504] do
        refute Shipping.definite_failure?({:http_status, status})
        refute Shipping.definite_failure?({:http_status, status, "x"})
      end

      for reason <- [
            :timeout,
            {:provider_crashed, "boom"},
            {:bad_return, "a map"},
            %Req.TransportError{reason: :timeout},
            %Req.TransportError{reason: :closed},
            {:rejected, :not_a_message},
            :not_supported
          ] do
        refute Shipping.definite_failure?(reason), inspect(reason)
      end
    end
  end
end
