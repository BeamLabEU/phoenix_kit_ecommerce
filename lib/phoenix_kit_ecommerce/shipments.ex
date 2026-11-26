defmodule PhoenixKitEcommerce.Shipments do
  @moduledoc """
  Shipments of paid orders: registering them with the carrier and the admin's
  resolutions (`PhoenixKitEcommerce.Shipment`, table
  `phoenix_kit_shop_shipments`).

  ## Registering

  `begin_shipment/2` checks that the order is paid, that its method's
  provider can register shipments (`Shipping.supports?/2`, before anything is
  written) and that the carrier still accepts the destination (the pickup
  point is still in the provider's list, and `validate_destination/3`), then
  inserts the shipment as `creating` in a transaction that holds the order
  row. The partial unique index over the live statuses refuses a second live
  shipment of the order: `{:error, :live_shipment_exists}`.

  `submit_shipment/2` then makes one attempt. The attempt runs in its own
  process under `PhoenixKitEcommerce.Shipments.TaskSupervisor` (started by
  `PhoenixKitEcommerce.children/0`), not linked to the caller: the caller
  waits for the answer, but a caller that dies meanwhile (a LiveView's
  `start_async` when the admin closes the tab) does not stop it, and the
  carrier's answer is still logged and stored. The attempt

    * claims the shipment (`submitted_at`, set only on a `creating` shipment
      no attempt has claimed, while the order is still `paid`): a second
      submit of the same shipment is `{:error, :shipment_changed}` and never
      reaches the carrier. A shipment whose order is no longer paid is
      `failed` without a call;
    * calls the carrier outside any transaction;
    * logs the answer, then stores it on condition that the shipment is still
      `creating` under its own claim:

      * an answer - `created`, with the tracking number;
      * a definite failure (`Shipping.definite_failure?/1`), or nothing sent
        (the provider does not support it, the context cannot be rebuilt) -
        `failed`;
      * anything else (a timeout, a crash, an ambiguous HTTP status...) -
        `unknown`. The admin checks the carrier's portal, then records the
        tracking number (`enter_tracking_number/3`) or marks it failed
        (`mark_failed/2`). It is never retried automatically.

  An Oban job would add nothing here: a job retried after a node restart may
  not call the carrier again (the claim refuses it), so a stale claim is left
  to the admin either way, and the admin wants the answer while waiting.

  An answer that arrives after the shipment has left `creating` changes
  nothing (`{:error, :shipment_changed}`; it is logged with the tracking
  number). `register/2` is the two steps in one.

  A `failed` shipment is retried on the same row (`retry_shipment/2`): the
  same checks, then a compare-and-set `failed -> creating`, and
  `submit_shipment/2` again. A conflict with another live shipment is
  `{:error, :live_shipment_exists}`, never a raise.

  ## The data sent

  The parcels, the recipient (`name`, `email`, `phone` from the order's
  `billing_snapshot`, the phone in E.164 beside the `raw_phone` as typed) and
  the destination are copied from
  the order; `begin_shipment/2` and `retry_shipment/2` take the admin's
  corrections as `:parcels`, `:recipient` and `:destination`.

  ## Masking

  The error and the events of a shipment are stored masked: the recipient's
  name, e-mail, phone and street address, and anything shaped like an e-mail
  address or an international phone number. The error is cut to 300
  characters; the last 50 events are kept.

  ## Callers

  Every function that changes a shipment takes `:actor_uuid` (who did it; it
  is recorded on the events, and as `created_by_uuid` on a new shipment).
  These functions write no Activity: the admin LiveView logs on success, as
  everywhere else in the module. Errors are atoms or tagged tuples with a
  clause in `PhoenixKitEcommerce.Errors.message/1`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.{Shipment, ShippingMethod}
  alias PhoenixKitEcommerce.Shipments.Mask
  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{CartQuote, Codec, Context, Destination, Parcel}
  alias PhoenixKitEcommerce.Shipping.{Service, ShipmentRef, ShipmentRequest, ShipmentResult}

  @task_supervisor PhoenixKitEcommerce.Shipments.TaskSupervisor
  @max_events 50
  @error_max 300
  @stuck_after_seconds 600
  @context_keys [:provider, :settings, :service, :country, :currency, :locale]
  @resolvable_statuses ["unknown"]
  @cancellable_statuses ["created", "in_transit", "ready_for_pickup"]
  @locally_cancellable_statuses ["unknown" | @cancellable_statuses]

  @type error ::
          :not_found
          | :order_not_paid
          | :no_shipping_method
          | :provider_changed
          | :unknown_provider
          | :unknown_service
          | :shipments_not_supported
          | :cancel_not_supported
          | :invalid_destination
          | :pickup_point_unavailable
          | {:destination_rejected, String.t()}
          | {:destination_unverified, term()}
          | :live_shipment_exists
          | :shipment_changed
          | :submit_crashed
          | :connection_changed
          | :connection_environment_changed
          | :tracking_number_required

  # -- reading ----------------------------------------------------------

  @doc "The shipment with `uuid`, or `nil`."
  @spec get_shipment(term()) :: Shipment.t() | nil
  def get_shipment(uuid) when is_binary(uuid) do
    case uuid_or_nil(uuid) do
      nil -> nil
      uuid -> repo().get(Shipment, uuid)
    end
  end

  def get_shipment(_uuid), do: nil

  @doc "The shipments of an order, the newest first."
  @spec list_order_shipments(String.t()) :: [Shipment.t()]
  def list_order_shipments(order_uuid) when is_binary(order_uuid) do
    repo().all(
      from(s in Shipment, where: s.order_uuid == ^order_uuid, order_by: [desc: s.inserted_at])
    )
  end

  @doc "What the provider is given about a stored shipment."
  @spec shipment_ref(Shipment.t()) :: ShipmentRef.t()
  def shipment_ref(%Shipment{} = shipment) do
    %ShipmentRef{
      carrier_ref: shipment.carrier_ref,
      tracking_number: shipment.tracking_number,
      service: shipment.service,
      extra: shipment.extra || %{}
    }
  end

  @doc """
  The request `create_shipment/2` is given for a shipment of `order`: the data
  sent stored on the shipment, the country of its context snapshot, and from
  the order its number, the payer, the goods description and their total.
  """
  @spec shipment_request(Shipment.t(), Order.t()) :: ShipmentRequest.t()
  def shipment_request(%Shipment{} = shipment, %Order{} = order) do
    goods = goods_lines(order)

    %ShipmentRequest{
      order_uuid: order.uuid,
      reference: order.order_number,
      service: shipment.service,
      country: shipment.context_snapshot |> Codec.get(:country) |> Codec.country(),
      destination: Destination.from_map(shipment.destination) || %Destination{},
      parcels: Codec.list(shipment.parcels, &Parcel.from_map/1),
      recipient: ShipmentRequest.recipient(shipment.recipient),
      payer: if(pay_on_delivery?(order), do: :recipient, else: :shop),
      description: goods |> Enum.map_join(", ", &goods_label/1) |> ShipmentRequest.description(),
      declared_value: goods_total(goods),
      currency: order.currency
    }
  end

  @doc """
  The provider context of a stored shipment, rebuilt from its
  `context_snapshot` (the provider, service and settings it was created with,
  and the connection named there). Refused when the connection is no longer
  the one the shipment was created through (`:connection_changed`) or now
  points to another environment (`:connection_environment_changed`).

  Options: `:context_opts`, passed to `Shipping.context/2` (`:timeout`,
  `:req_options`...).
  """
  @spec shipment_context(Shipment.t(), keyword()) :: {:ok, Context.t()} | {:error, error()}
  def shipment_context(%Shipment{} = shipment, opts \\ []) do
    snapshot = shipment.context_snapshot || %{}
    method = shipment.method_uuid && repo().get(ShippingMethod, shipment.method_uuid)

    ctx =
      Shipping.context(
        method,
        present(
          provider: shipment.provider,
          settings: snapshot |> Codec.get(:settings) |> Codec.string_map(),
          service: shipment.service,
          country: snapshot |> Codec.get(:country) |> Codec.country(),
          currency: snapshot |> Codec.get(:currency) |> Codec.string(),
          locale: snapshot |> Codec.get(:locale) |> Codec.string()
        ) ++ context_opts(opts)
      )

    cond do
      is_nil(ctx.provider) ->
        {:error, :unknown_provider}

      not is_nil(shipment.integration_uuid) and ctx.integration_uuid != shipment.integration_uuid ->
        {:error, :connection_changed}

      environment(ctx.credentials) != snapshot |> Codec.get(:environment) |> Codec.string() ->
        {:error, :connection_environment_changed}

      true ->
        {:ok, ctx}
    end
  end

  # -- registering ------------------------------------------------------

  @doc """
  Registers a shipment of a paid order: `begin_shipment/2`, then
  `submit_shipment/2`. Takes the options of both.
  """
  @spec register(Order.t() | String.t(), keyword()) :: {:ok, Shipment.t()} | {:error, error()}
  def register(order, opts \\ []) do
    with {:ok, shipment} <- begin_shipment(order, opts), do: submit_shipment(shipment, opts)
  end

  @doc """
  Checks an order and inserts its shipment as `creating` (see the moduledoc).
  The carrier is not called.

  Options: `:actor_uuid`; `:parcels` (`Parcel`s or maps), `:recipient`
  (`%{name, email, phone}`) and `:destination` (a `Destination` or a map), the
  admin's corrections of what the order says; `:context_opts`.
  """
  @spec begin_shipment(Order.t() | String.t(), keyword()) ::
          {:ok, Shipment.t()} | {:error, error()}
  def begin_shipment(order, opts \\ []) do
    with {:ok, order} <- fetch_paid_order(order),
         {:ok, ctx} <- order_context(order, opts),
         data = sent_data(order, ctx, opts),
         :ok <- check_destination(ctx, data.destination) do
      shipment =
        struct(
          Shipment,
          Map.merge(data, %{
            order_uuid: order.uuid,
            status: "creating",
            created_by_uuid: opts[:actor_uuid],
            events: [event("register", "creating", opts[:actor_uuid], nil)]
          })
        )

      under_paid_order(order.uuid, fn -> insert(shipment) end)
    end
  end

  @doc """
  Makes one attempt to register a `creating` shipment with the carrier (see
  the moduledoc) and waits for it: `{:ok, shipment}` in `created`, `failed`
  or `unknown`. `{:error, :shipment_changed}` when the shipment is not
  `creating`, another attempt has claimed it, or it left `creating` before
  the answer was stored; nothing is written then. `{:error,
  :submit_crashed}` when the attempt itself crashed (the shipment is left to
  the admin like one stuck in `creating`).

  Options: `:actor_uuid`, `:context_opts` (`:timeout` bounds the carrier
  call, 30 seconds by default).
  """
  @spec submit_shipment(Shipment.t(), keyword()) :: {:ok, Shipment.t()} | {:error, error()}
  def submit_shipment(%Shipment{uuid: uuid}, opts \\ []) do
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> attempt(uuid, opts) end)

    case Task.yield(task, :infinity) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("Shipment #{uuid}: the attempt crashed: #{Exception.format_exit(reason)}")
        {:error, :submit_crashed}
    end
  end

  defp attempt(uuid, opts) do
    actor_uuid = opts[:actor_uuid]

    case claim(uuid, actor_uuid) do
      {:claimed, shipment, order} ->
        outcome =
          case shipment_context(shipment, opts) do
            {:ok, ctx} -> Shipping.create_shipment(ctx, shipment_request(shipment, order))
            {:error, reason} -> {:error, {:not_sent, reason}}
          end

        log_outcome(shipment, outcome)
        store_outcome(shipment, outcome, actor_uuid)

      {:refused, result} ->
        result

      {:error, _reason} = error ->
        error
    end
  end

  # One attempt per claim: `submitted_at` is set only on a `creating` shipment
  # that no attempt holds, with the order row held and still `paid`.
  defp claim(uuid, actor_uuid) do
    with %Shipment{status: "creating", submitted_at: nil} = shipment <-
           get_shipment(uuid) || {:error, :not_found},
         {:ok, claimed} <-
           repo().transaction(fn -> claim_under_order(shipment, actor_uuid) end) do
      claimed
    else
      %Shipment{} -> {:error, :shipment_changed}
      {:error, _reason} = error -> error
    end
  end

  defp claim_under_order(shipment, actor_uuid) do
    order =
      repo().one(from(o in Order, where: o.uuid == ^shipment.order_uuid, lock: "FOR SHARE"))

    case order do
      %Order{status: "paid"} ->
        now = DateTime.utc_now()

        shipment.uuid
        |> compare_and_set(["creating"], [submitted_at: now],
          unclaimed: true,
          event: event("submit", "creating", actor_uuid, nil)
        )
        |> then(fn
          {:ok, claimed} -> {:claimed, claimed, order}
          error -> error
        end)

      _not_paid ->
        changes = [status: "failed", error: "order_not_paid"]

        {:refused,
         compare_and_set(shipment.uuid, ["creating"], changes,
           unclaimed: true,
           event: event("result", "failed", actor_uuid, "order_not_paid")
         )}
    end
  end

  # The answer is in the log before the write, so a write that fails still
  # leaves the admin the tracking number. The reason of a failure is not: it
  # may quote the recipient (the facade logged its shape).
  defp log_outcome(shipment, {:ok, %ShipmentResult{} = result}) do
    Logger.info(
      "Shipment #{shipment.uuid}: the carrier registered it, tracking number " <>
        "#{inspect(result.tracking_number)}, carrier reference #{inspect(result.carrier_ref)}"
    )
  end

  defp log_outcome(shipment, {:error, reason}) do
    status = if definite?(reason), do: "failed", else: "unknown"
    Logger.info("Shipment #{shipment.uuid}: the carrier call ended #{status}")
  end

  @doc """
  Retries a `failed` shipment on the same row: the checks of
  `begin_shipment/2` (with a fresh context snapshot of the method), then a
  compare-and-set `failed -> creating`. Call `submit_shipment/2` next.
  `{:error, :shipment_changed}` when it is not `failed` any more,
  `{:error, :live_shipment_exists}` when the order has another live shipment.

  Options as `begin_shipment/2`; the corrections default to what the
  shipment sent last time.
  """
  @spec retry_shipment(Shipment.t(), keyword()) :: {:ok, Shipment.t()} | {:error, error()}
  def retry_shipment(%Shipment{} = shipment, opts \\ []) do
    with %Shipment{status: "failed"} = shipment <- get_shipment(shipment.uuid) || :not_found,
         {:ok, order} <- fetch_paid_order(shipment.order_uuid),
         {:ok, ctx} <- order_context(order, opts),
         data = sent_data(order, ctx, previous_data(shipment, opts)),
         :ok <- check_destination(ctx, data.destination) do
      changes =
        data
        |> Map.merge(%{
          status: "creating",
          error: nil,
          submitted_at: nil
        })
        |> Map.to_list()

      retry = event("retry", "creating", opts[:actor_uuid], nil)

      under_paid_order(order.uuid, fn ->
        compare_and_set(shipment.uuid, ["failed"], changes, event: retry)
      end)
    else
      :not_found -> {:error, :not_found}
      %Shipment{} -> {:error, :shipment_changed}
      error -> error
    end
  end

  # -- the admin's resolutions ------------------------------------------

  @doc """
  Records that the carrier does not have an `unknown` shipment (or one stuck
  in `creating` for 10 minutes): `failed`, so it can be retried.

  Options: `:actor_uuid`.
  """
  @spec mark_failed(Shipment.t(), keyword()) :: {:ok, Shipment.t()} | {:error, error()}
  def mark_failed(%Shipment{} = shipment, opts \\ []) do
    resolve(shipment, @resolvable_statuses, true, "mark_failed", "failed", [], opts)
  end

  @doc """
  Records the tracking number the admin found in the carrier's portal for an
  `unknown` shipment (or one stuck in `creating` for 10 minutes): `created`.

  Options: `:actor_uuid`, `:tracking_url`, `:carrier_ref`.
  """
  @spec enter_tracking_number(Shipment.t(), String.t(), keyword()) ::
          {:ok, Shipment.t()} | {:error, error()}
  def enter_tracking_number(%Shipment{} = shipment, tracking_number, opts \\ []) do
    case tracking_number |> Codec.string() |> blank_to_nil() do
      nil ->
        {:error, :tracking_number_required}

      number ->
        changes = [
          tracking_number: number,
          tracking_url: opts |> Keyword.get(:tracking_url) |> Codec.string() |> blank_to_nil(),
          carrier_ref: opts |> Keyword.get(:carrier_ref) |> Codec.string() |> blank_to_nil()
        ]

        resolve(
          shipment,
          @resolvable_statuses,
          true,
          "tracking_entered",
          "created",
          changes,
          opts
        )
    end
  end

  @doc """
  Records that the shipment was cancelled at the carrier (in its portal):
  `cancelled`, locally only. Offered for every provider, for a shipment in
  `unknown`, `created`, `in_transit` or `ready_for_pickup` (or stuck in
  `creating` for 10 minutes).

  Options: `:actor_uuid`.
  """
  @spec mark_cancelled_at_carrier(Shipment.t(), keyword()) ::
          {:ok, Shipment.t()} | {:error, error()}
  def mark_cancelled_at_carrier(%Shipment{} = shipment, opts \\ []) do
    resolve(
      shipment,
      @locally_cancellable_statuses,
      true,
      "cancelled_at_carrier",
      "cancelled",
      [],
      opts
    )
  end

  @doc """
  Cancels a `created`, `in_transit` or `ready_for_pickup` shipment at the
  carrier (the provider's `cancel_shipment/2`), then records it `cancelled`.
  `{:error, :cancel_not_supported}` for a provider without the callback;
  the carrier's refusal is returned as it is and nothing is written.

  Options: `:actor_uuid`, `:context_opts`.
  """
  @spec cancel_shipment(Shipment.t(), keyword()) :: {:ok, Shipment.t()} | {:error, term()}
  def cancel_shipment(%Shipment{} = shipment, opts \\ []) do
    with %Shipment{} = shipment <- get_shipment(shipment.uuid) || {:error, :not_found},
         :ok <- in_status(shipment, @cancellable_statuses),
         {:ok, ctx} <- shipment_context(shipment, opts),
         :ok <-
           if(Shipping.supports?(ctx, :cancel_shipment),
             do: :ok,
             else: {:error, :cancel_not_supported}
           ),
         :ok <- Shipping.cancel_shipment(ctx, shipment_ref(shipment)) do
      resolve(shipment, @cancellable_statuses, false, "cancelled", "cancelled", [], opts)
    end
  end

  # -- the order ---------------------------------------------------------

  defp fetch_paid_order(%Order{uuid: uuid}), do: fetch_paid_order(uuid)

  defp fetch_paid_order(uuid) do
    case fetch_order(uuid) do
      %Order{status: "paid"} = order -> {:ok, order}
      %Order{} -> {:error, :order_not_paid}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_order(uuid) when is_binary(uuid) do
    case uuid_or_nil(uuid) do
      nil -> nil
      uuid -> repo().get(Order, uuid)
    end
  end

  defp fetch_order(_uuid), do: nil

  # The insert (or the retry's compare-and-set) runs with the order row held,
  # so a refund or a cancellation cannot slip in between the check and the
  # write.
  defp under_paid_order(order_uuid, fun) do
    repo().transaction(fn ->
      from(o in Order, where: o.uuid == ^order_uuid, lock: "FOR SHARE")
      |> repo().one()
      |> while_paid(fun)
      |> case do
        {:ok, shipment} -> shipment
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if live_conflict?(error),
        do: {:error, :live_shipment_exists},
        else: reraise(error, __STACKTRACE__)
  end

  defp while_paid(%Order{status: "paid"}, fun), do: fun.()
  defp while_paid(%Order{}, _fun), do: {:error, :order_not_paid}
  defp while_paid(nil, _fun), do: {:error, :not_found}

  defp live_conflict?(%Postgrex.Error{postgres: %{code: :unique_violation} = postgres}),
    do: postgres[:constraint] == Atom.to_string(Shipment.live_index())

  defp live_conflict?(_error), do: false

  defp order_context(order, opts) do
    metadata = order.metadata || %{}
    stored = Codec.get(metadata, :shipping_provider) || %{}

    with %ShippingMethod{} = method <- order_method(metadata) || {:error, :no_shipping_method},
         ctx =
           Shipping.context(
             method,
             present(
               service: Codec.string(Codec.get(stored, :service)),
               country: order_country(order),
               currency: order.currency
             ) ++ context_opts(opts)
           ),
         :ok <- same_provider(ctx, Codec.string(Codec.get(stored, :provider))) do
      if Shipping.supports?(ctx, :create_shipment),
        do: {:ok, ctx},
        else: {:error, :shipments_not_supported}
    end
  end

  defp order_method(metadata) do
    case metadata |> Codec.get(:shipping_method_uuid) |> Codec.string() |> uuid_or_nil() do
      nil -> nil
      uuid -> repo().get(ShippingMethod, uuid)
    end
  end

  defp uuid_or_nil(nil), do: nil

  defp uuid_or_nil(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  # The destination of the order is the provider's own (its point ids): a
  # method switched to another provider since cannot send it.
  defp same_provider(%Context{provider: nil}, _stored), do: {:error, :unknown_provider}
  defp same_provider(_ctx, nil), do: :ok

  defp same_provider(%Context{provider: provider}, stored) do
    if provider.key() == stored, do: :ok, else: {:error, :provider_changed}
  end

  defp order_country(order) do
    Codec.country(Codec.get(order.metadata || %{}, :shipping_country)) ||
      Codec.country(Codec.get(order.billing_snapshot || %{}, :country))
  end

  # A missing fact is left to the method's default rather than set to `nil`.
  defp present(options), do: Enum.reject(options, fn {_key, value} -> is_nil(value) end)

  # The order's own facts win over the caller's context options.
  defp context_opts(opts),
    do: opts |> Keyword.get(:context_opts, []) |> Keyword.drop(@context_keys)

  # -- the data sent -----------------------------------------------------

  defp sent_data(order, ctx, opts) do
    metadata = order.metadata || %{}
    country = ctx.country

    %{
      method_uuid: ctx.method && ctx.method.uuid,
      integration_uuid: ctx.integration_uuid,
      provider: ctx.provider.key(),
      service: ctx.service,
      context_snapshot: context_snapshot(ctx),
      parcels:
        opts
        |> Keyword.get_lazy(:parcels, fn -> Codec.get(metadata, :shipping_parcels) end)
        |> Codec.list(&Codec.struct_from(&1, Parcel))
        |> Enum.map(&Parcel.to_map/1),
      recipient:
        opts
        |> Keyword.get_lazy(:recipient, fn -> billing_recipient(order.billing_snapshot) end)
        |> recipient_map(country),
      destination:
        opts
        |> Keyword.get_lazy(:destination, fn -> Codec.get(metadata, :shipping_destination) end)
        |> Codec.struct_from(Destination)
        |> Kernel.||(%Destination{})
        |> Destination.to_map()
    }
  end

  defp previous_data(shipment, opts) do
    opts
    |> Keyword.put_new(:parcels, shipment.parcels)
    |> Keyword.put_new(:recipient, shipment.recipient)
    |> Keyword.put_new(:destination, shipment.destination)
  end

  defp context_snapshot(%Context{} = ctx) do
    settings =
      if ctx.integration_uuid,
        do: Map.put(ctx.settings || %{}, "integration", ctx.integration_uuid),
        else: ctx.settings || %{}

    %{
      "settings" => Codec.dump(settings),
      "environment" => environment(ctx.credentials),
      "country" => ctx.country,
      "currency" => ctx.currency,
      "locale" => ctx.locale
    }
  end

  defp environment(credentials) when is_map(credentials),
    do: credentials |> Codec.get(:environment) |> Codec.string()

  defp environment(_credentials), do: nil

  defp billing_recipient(snapshot) when is_map(snapshot) do
    name =
      if Codec.get(snapshot, :type) == "company" and filled?(Codec.get(snapshot, :company_name)),
        do: Codec.get(snapshot, :company_name),
        else:
          [Codec.get(snapshot, :first_name), Codec.get(snapshot, :last_name)]
          |> Enum.filter(&filled?/1)
          |> Enum.join(" ")

    %{name: name, email: Codec.get(snapshot, :email), phone: Codec.get(snapshot, :phone)}
  end

  defp billing_recipient(_snapshot), do: %{}

  # The number as it was typed is kept beside the normalised one: a stored
  # recipient (a retry) carries both, a new one only the typed `phone`.
  defp recipient_map(recipient, country) do
    %{name: name, email: email, phone: phone, raw_phone: raw} =
      ShipmentRequest.recipient(recipient)

    raw = raw || phone

    %{
      "name" => name,
      "email" => email,
      "phone" => ShipmentRequest.e164_phone(raw, country),
      "raw_phone" => raw
    }
  end

  defp goods_lines(%Order{line_items: lines}) when is_list(lines),
    do: Enum.reject(lines, &(is_map(&1) and Codec.get(&1, :type) == "shipping"))

  defp goods_lines(_order), do: []

  defp goods_label(line) do
    name = line |> Codec.get(:name) |> Codec.string() || ""

    case line |> Codec.get(:quantity) |> Codec.integer() do
      quantity when is_integer(quantity) and quantity > 1 -> "#{name} x#{quantity}"
      _one -> name
    end
  end

  defp goods_total(lines) do
    Enum.reduce(lines, Decimal.new(0), fn line, acc ->
      Decimal.add(acc, line |> Codec.get(:total) |> Codec.decimal() || Decimal.new(0))
    end)
  end

  defp pay_on_delivery?(order),
    do: Codec.get(order.metadata || %{}, :shipping_pay_on_delivery) == true

  # -- the destination ---------------------------------------------------

  defp check_destination(ctx, destination_map) do
    destination = Destination.from_map(destination_map) || %Destination{}

    with {:ok, service} <- service_of(ctx),
         :ok <- complete(service, destination),
         :ok <- point_listed(ctx, service, destination) do
      case Shipping.validate_destination(ctx, destination, service) do
        :ok -> :ok
        {:error, message} -> {:error, {:destination_rejected, message}}
      end
    end
  end

  defp service_of(ctx) do
    case Shipping.services(ctx) do
      {:ok, services} ->
        case Enum.find(services, &(&1.key == ctx.service)) do
          %Service{} = service -> {:ok, service}
          nil -> {:error, :unknown_service}
        end

      {:error, reason} ->
        {:error, {:destination_unverified, reason}}
    end
  end

  defp complete(%Service{destination: kind}, destination) do
    if CartQuote.incomplete?(kind, destination), do: {:error, :invalid_destination}, else: :ok
  end

  # A point the shopper found in the provider's list must still be in it. A
  # point typed in by hand, or one without a locality to list, is left to
  # `validate_destination/3`.
  defp point_listed(
         ctx,
         %Service{destination: :pickup_point, lookup: :search},
         %Destination{locality: %{} = locality, pickup_point: %{id: id}}
       ) do
    case Shipping.list_pickup_points(ctx, locality, nil, fresh: true) do
      {:ok, points} ->
        if Enum.any?(points, &(&1.id == id)), do: :ok, else: {:error, :pickup_point_unavailable}

      {:error, :not_supported} ->
        :ok

      {:error, reason} ->
        {:error, {:destination_unverified, reason}}
    end
  end

  defp point_listed(_ctx, _service, _destination), do: :ok

  # -- writing -----------------------------------------------------------

  defp insert(%Shipment{} = shipment) do
    shipment
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:order_uuid, name: Shipment.live_index())
    |> Ecto.Changeset.foreign_key_constraint(:order_uuid, name: :fk_shop_shipments_order_uuid)
    |> repo().insert()
    |> case do
      {:ok, shipment} ->
        {:ok, shipment}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :order_uuid) and
             match?({_, [{:constraint, :unique} | _]}, changeset.errors[:order_uuid]),
           do: {:error, :live_shipment_exists},
           else: {:error, changeset}
    end
  end

  defp store_outcome(shipment, {:ok, %ShipmentResult{} = result}, actor_uuid) do
    changes = [
      status: "created",
      tracking_number: result.tracking_number,
      tracking_url: result.tracking_url,
      carrier_ref: result.carrier_ref,
      carrier_label: result.carrier_label,
      extra: Codec.string_map(Codec.dump(result.extra)),
      error: nil
    ]

    case compare_and_set(shipment.uuid, ["creating"], changes,
           claim: shipment.submitted_at,
           event: event("result", "created", actor_uuid, nil)
         ) do
      {:ok, stored} ->
        {:ok, stored}

      {:error, :shipment_changed} = changed ->
        Logger.warning(
          "Shipment #{shipment.uuid} was registered by the carrier after it left " <>
            "\"creating\" (tracking number #{inspect(result.tracking_number)}); not stored"
        )

        changed
    end
  end

  defp store_outcome(shipment, {:error, reason}, actor_uuid) do
    status = if definite?(reason), do: "failed", else: "unknown"
    message = shipment |> masked(error_text(reason)) |> cut()

    compare_and_set(
      shipment.uuid,
      ["creating"],
      [status: status, error: message],
      claim: shipment.submitted_at,
      event: event("result", status, actor_uuid, message)
    )
  end

  # Nothing reached the carrier when the context could not be rebuilt, or the
  # facade had no callback to call.
  defp definite?({:not_sent, _reason}), do: true
  defp definite?(reason) when reason in [:not_supported, :unknown_provider], do: true
  defp definite?(reason), do: Shipping.definite_failure?(reason)

  defp resolve(shipment, statuses, stuck?, action, status, changes, opts) do
    with %Shipment{} = shipment <- get_shipment(shipment.uuid) || {:error, :not_found} do
      compare_and_set(shipment.uuid, statuses, [{:status, status} | changes],
        stuck: stuck?,
        event: event(action, status, opts[:actor_uuid], nil)
      )
    end
  end

  defp in_status(%Shipment{status: status}, statuses) do
    if status in statuses, do: :ok, else: {:error, :shipment_changed}
  end

  # The write happens only while the shipment is in one of `statuses` (or, with
  # `stuck: true`, still `creating` after 10 minutes), and, with `unclaimed:
  # true`, no attempt holds it, or with `claim: at`, the attempt of that claim
  # does: two writers racing for the same transition cannot both win. The
  # `:event` is appended by the same statement, to the events the row has
  # then, so an event another writer added meanwhile is kept.
  defp compare_and_set(uuid, statuses, changes, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(s in Shipment, where: s.uuid == ^uuid, select: s)
      |> where_status(statuses, Keyword.get(opts, :stuck, false), now)
      |> where_claim(opts)
      |> append_event(Keyword.fetch!(opts, :event))

    case repo().update_all(query, set: Keyword.put(changes, :updated_at, now)) do
      {1, [shipment]} -> {:ok, shipment}
      {0, _none} -> {:error, :shipment_changed}
    end
  end

  defp where_status(query, statuses, false, _now),
    do: from(s in query, where: s.status in ^statuses)

  defp where_status(query, statuses, true, now) do
    cutoff = DateTime.add(now, -@stuck_after_seconds, :second)

    from(s in query,
      where: s.status in ^statuses or (s.status == "creating" and s.updated_at < ^cutoff)
    )
  end

  defp where_claim(query, opts) do
    cond do
      Keyword.get(opts, :unclaimed, false) ->
        from(s in query, where: is_nil(s.submitted_at))

      Keyword.has_key?(opts, :claim) ->
        claim = Keyword.fetch!(opts, :claim)
        from(s in query, where: s.submitted_at == ^claim)

      true ->
        query
    end
  end

  # The last #{@max_events} of the stored events and the new one.
  defp append_event(query, event) do
    added = Jason.encode!([event])

    from(s in query,
      update: [
        set: [
          events:
            fragment(
              """
              (SELECT coalesce(jsonb_agg(t.e ORDER BY t.n), '[]'::jsonb)
               FROM jsonb_array_elements(? || ?::text::jsonb) WITH ORDINALITY AS t(e, n)
               WHERE t.n > jsonb_array_length(? || ?::text::jsonb) - ?)
              """,
              s.events,
              ^added,
              s.events,
              ^added,
              ^@max_events
            )
        ]
      ]
    )
  end

  defp event(action, status, actor_uuid, message) do
    %{
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "action" => action,
      "status" => status,
      "actor_uuid" => actor_uuid,
      "message" => message
    }
  end

  # -- error text --------------------------------------------------------

  defp masked(shipment, text),
    do: Mask.text(text, shipment.recipient || %{}, shipment.destination || %{})

  defp cut(nil), do: nil
  defp cut(text), do: String.slice(text, 0, @error_max)

  defp error_text({:rejected, message}) when is_binary(message), do: message
  defp error_text({:not_sent, reason}), do: error_text(reason)
  defp error_text({:http_status, status}), do: "HTTP #{status}"

  defp error_text({:http_status, status, detail}) when is_binary(detail),
    do: "HTTP #{status}: #{detail}"

  defp error_text({:http_status, status, _detail}), do: "HTTP #{status}"

  defp error_text({:provider_crashed, message}) when is_binary(message),
    do: "crashed: " <> message

  defp error_text({:bad_return, shape}) when is_binary(shape), do: "unexpected answer: " <> shape
  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_text(reason), do: inspect(reason, limit: 20, printable_limit: @error_max)

  defp filled?(value), do: is_binary(value) and String.trim(value) != ""

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
