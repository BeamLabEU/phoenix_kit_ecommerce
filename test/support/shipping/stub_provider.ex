defmodule PhoenixKitEcommerce.Test.Shipping.StubProvider do
  @moduledoc """
  Configurable `PhoenixKitEcommerce.Shipping.Provider` for tests.

  The behaviour is a map, given either through the context option `:stub`
  (`Shipping.context(method, stub: %{...})`) or stored in the test process
  with `put/1`; the facade runs the provider in a task, so the lookup also
  walks `$callers`.

  Keys (all optional):

    * `:services` - list of `Service`
    * `:localities` - list, `{:error, reason}` or `fn query -> ... end`
      (`fn query, ctx -> ... end` to see the context)
    * `:points` - list, `{:error, reason}` or `fn locality, service, query -> ... end`
      (`fn locality, service, query, ctx -> ... end` to see the context)
    * `:quote` - `Quote`, `{:error, reason}` or `fn request, ctx -> ... end`
    * `:create` - `ShipmentResult`, `{:error, reason}` or `fn request, ctx -> ... end`
      (`create_shipment/2`; default: a result with a tracking number)
    * `:cancel` - `:ok`, `{:error, reason}` or `fn ref, ctx -> ... end`
    * `:labels` - the answer of `print_labels/3`, or `fn refs, options, ctx -> ... end`
    * `:track` - the answer of `track/2`, or `fn refs, ctx -> ... end`
    * `:mode` - `:ok` (default), `:crash`, `:hang` or `:bad_return`, for every
      operation; `:modes` is a `%{operation => mode}` override
    * `:notify` - pid that gets `{:stub_called, operation, args}` (defaults to the caller)
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  alias PhoenixKitEcommerce.Shipping.{Context, Field, Locality, PickupPoint, Quote, Service}
  alias PhoenixKitEcommerce.Shipping.ShipmentResult

  @key :shipping_stub_config

  @defaults %{
    services: [
      %Service{
        key: "branch",
        label: "To a branch",
        destination: :pickup_point,
        lookup: :search,
        point_code_label: "Branch number"
      },
      %Service{key: "courier", label: "Courier", destination: :address}
    ],
    localities: [],
    points: [],
    quote: nil,
    create: nil,
    cancel: :ok,
    labels: {:ok, %{content_type: "application/pdf", body: "%PDF-stub"}},
    track: {:ok, []},
    mode: :ok,
    modes: %{},
    notify: nil
  }

  @doc "Stores the behaviour in the calling process."
  @spec put(map()) :: :ok
  def put(config) when is_map(config) do
    Process.put(@key, config)
    :ok
  end

  @impl true
  def key, do: "stub"

  @impl true
  def label, do: "Stub carrier"

  @impl true
  def services(%Context{} = ctx) do
    run(:services, ctx, [], fn config -> config.services end)
  end

  @impl true
  def settings_fields do
    [%Field{key: "sender_city", label: "Sender city", type: :locality, required: true}]
  end

  @impl true
  def quote(request, %Context{} = ctx) do
    run(:quote, ctx, [request], fn
      %{quote: %Quote{} = fixed} -> {:ok, fixed}
      %{quote: {:error, _} = error} -> error
      %{quote: fun} when is_function(fun, 2) -> fun.(request, ctx)
      _config -> {:ok, %Quote{amount: Decimal.new(100), currency: ctx.currency, source: :api}}
    end)
  end

  @impl true
  def search_localities(query, %Context{} = ctx) do
    run(:search_localities, ctx, [query], fn
      %{localities: fun} when is_function(fun, 1) -> fun.(query)
      %{localities: fun} when is_function(fun, 2) -> fun.(query, ctx)
      %{localities: {:error, _} = error} -> error
      %{localities: list} -> {:ok, list}
    end)
  end

  @impl true
  def list_pickup_points(%Locality{} = locality, service, query, %Context{} = ctx) do
    run(:list_pickup_points, ctx, [locality, service, query], fn
      %{points: fun} when is_function(fun, 3) -> fun.(locality, service, query)
      %{points: fun} when is_function(fun, 4) -> fun.(locality, service, query, ctx)
      %{points: {:error, _} = error} -> error
      %{points: list} -> {:ok, list}
    end)
  end

  @impl true
  def create_shipment(request, %Context{} = ctx) do
    run(:create_shipment, ctx, [request], fn
      %{create: %ShipmentResult{} = result} -> {:ok, result}
      %{create: {:error, _} = error} -> error
      %{create: fun} when is_function(fun, 2) -> fun.(request, ctx)
      _config -> {:ok, %ShipmentResult{carrier_ref: "C-1", tracking_number: "TRK-1"}}
    end)
  end

  @impl true
  def cancel_shipment(ref, %Context{} = ctx) do
    run(:cancel_shipment, ctx, [ref], fn
      %{cancel: fun} when is_function(fun, 2) -> fun.(ref, ctx)
      %{cancel: answer} -> answer
    end)
  end

  @impl true
  def print_labels(refs, options, %Context{} = ctx) do
    run(:print_labels, ctx, [refs, options], fn
      %{labels: fun} when is_function(fun, 3) -> fun.(refs, options, ctx)
      %{labels: answer} -> answer
    end)
  end

  @impl true
  def track(refs, %Context{} = ctx) do
    run(:track, ctx, [refs], fn
      %{track: fun} when is_function(fun, 2) -> fun.(refs, ctx)
      %{track: answer} -> answer
    end)
  end

  @impl true
  def integration do
    %{
      key: "stub",
      name: "Stub carrier",
      auth_type: :api_key,
      setup_fields: [%{key: "api_key", label: "API key", type: :password, required: true}],
      capabilities: [:shipping]
    }
  end

  @doc "A pickup point with the given limits, for filtering tests."
  @spec point(String.t(), map()) :: PickupPoint.t()
  def point(id, limits \\ %{}) do
    %PickupPoint{
      id: id,
      name: "Point #{id}",
      limits: Map.merge(%{max_weight_g: nil, max_dims_mm: nil, max_declared: nil}, limits)
    }
  end

  defp run(operation, ctx, args, fun) do
    config = config(ctx)
    send(notify_pid(config), {:stub_called, operation, args})

    case Map.get(config.modes, operation, config.mode) do
      :ok -> fun.(config)
      :crash -> raise "stub #{operation} crashed"
      :hang -> Process.sleep(:infinity)
      :bad_return -> :nonsense
    end
  end

  defp config(%Context{opts: opts}) do
    stored =
      case Keyword.get(opts, :stub) do
        %{} = stub -> stub
        _ -> [self() | Process.get(:"$callers", [])] |> Enum.find_value(%{}, &stored_config/1)
      end

    Map.merge(@defaults, stored)
  end

  defp stored_config(pid) do
    if pid == self() do
      Process.get(@key)
    else
      case Process.info(pid, :dictionary) do
        {:dictionary, dictionary} -> Keyword.get(dictionary, @key)
        nil -> nil
      end
    end
  end

  defp notify_pid(%{notify: pid}) when is_pid(pid), do: pid
  defp notify_pid(_config), do: List.first(Process.get(:"$callers", [])) || self()
end
