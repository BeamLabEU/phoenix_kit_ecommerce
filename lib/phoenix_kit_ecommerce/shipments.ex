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
  number). `register/2` is the two steps in one. A shipment that waits in
  `creating` for 10 minutes is moved to `unknown` by `sweep_stuck/0`.

  A `failed` shipment is retried on the same row (`retry_shipment/2`): the
  same checks, then a compare-and-set `failed -> creating`, and
  `submit_shipment/2` again. A conflict with another live shipment is
  `{:error, :live_shipment_exists}`, never a raise.

  ## Tracking

  `track_shipments/1` asks the carriers for the state of the `created`,
  `in_transit` and `ready_for_pickup` shipments that are less than 60 days
  old (see its doc). A status never moves backwards, and every write is
  conditional on the status the update was weighed against.

  ## The buyer's e-mail

  The buyer's "shipped" e-mail (`PhoenixKitEcommerce.OrderEmails`, once per
  shipment) is queued when tracking first moves a shipment to `in_transit`,
  `ready_for_pickup` or `delivered`, in the transaction of that write; for a
  provider without `track/2`, when the shipment becomes `created` (the
  carrier's answer, or the tracking number the admin entered), after that
  write and without ever failing it: the carrier's answer is not lost to the
  e-mail. `shipped?/1` is the same rule.

  ## The data sent

  The parcels, the recipient (`name`, `company`, `email`, `phone` from the order's
  `billing_snapshot`, the phone in E.164 beside the `raw_phone` as typed) and
  the destination are copied from
  the order; `begin_shipment/2` and `retry_shipment/2` take the admin's
  corrections as `:parcels`, `:recipient` and `:destination`. A recipient
  correction changes only the fields it names (a blank one clears it); one
  that is not a map is `{:error, :invalid_recipient}`.

  ## Masking

  The error and the events of a shipment are stored masked: the recipient's
  name, e-mail, phone and street address, and anything shaped like an e-mail
  address or an international phone number. The error is cut to 300
  characters; the last 50 events are kept.

  ## Callers

  `submit_shipment/2` and `register/2` must not be called inside a
  transaction (they raise `ArgumentError`): the attempt runs in its own
  process, which would wait for the rows the caller's transaction holds, and
  the carrier call must not sit inside a transaction.

  Every function that changes a shipment takes `:actor_uuid` (who did it; it
  is recorded on the events, and as `created_by_uuid` on a new shipment).
  These functions write no Activity: the admin LiveView logs on success, as
  everywhere else in the module. Errors are atoms or tagged tuples with a
  clause in `PhoenixKitEcommerce.Errors.message/1`.
  """

  import Ecto.Query, only: [from: 2, exclude: 2]

  require Logger

  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.{OrderEmails, Shipment, ShippingMethod}
  alias PhoenixKitEcommerce.Shipments.Mask
  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{CartQuote, Codec, Context, Destination, LabelOptions}
  alias PhoenixKitEcommerce.Shipping.{MethodConfig, Parcel}
  alias PhoenixKitEcommerce.Shipping.{Service, ShipmentRef, ShipmentRequest, ShipmentResult}
  alias PhoenixKitEcommerce.Shipping.TrackingUpdate

  @task_supervisor PhoenixKitEcommerce.Shipments.TaskSupervisor
  @max_events 50
  @recipient_keys [:name, :company, :email, :phone, :raw_phone]
  @error_max 300
  @stuck_after_seconds 600
  @context_keys [:provider, :settings, :service, :country, :currency, :locale]
  @resolvable_statuses ["unknown"]
  @cancellable_statuses ["created", "in_transit", "ready_for_pickup"]
  @locally_cancellable_statuses ["unknown" | @cancellable_statuses]
  @closed_order_statuses ["cancelled", "refunded"]
  @open_statuses ["creating" | @cancellable_statuses]
  @attention_statuses ["unknown", "failed" | @open_statuses]
  @list_limit 200
  @max_labels 50
  @max_url_length 2048
  @shipped_statuses ["in_transit", "ready_for_pickup", "delivered"]
  @buyer_statuses ["created" | @shipped_statuses] ++ ["returned"]
  @tracking_days 60
  @track_limit 1000
  # An update moves a shipment only to a higher rank. The return leg ranks
  # above the outbound one, and the carrier's cancellation with it: both are
  # terminal.
  @rank %{
    "created" => 0,
    "in_transit" => 1,
    "ready_for_pickup" => 2,
    "delivered" => 3,
    "returned" => 4,
    "cancelled" => 4
  }

  @type error ::
          :not_found
          | :order_not_paid
          | :no_shipping_method
          | :provider_changed
          | :unknown_provider
          | :unknown_service
          | :shipments_not_supported
          | :cancel_not_supported
          | {:cancel_refused, String.t()}
          | {:cancel_unconfirmed, String.t()}
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
          | :invalid_recipient
          | :invalid_tracking_url
          | :order_not_closed
          | :invalid_shipment_ids
          | :too_many_labels
          | :mixed_label_providers
          | :labels_not_supported
          | :label_unavailable
          | {:labels_failed, term()}

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
      from(s in Shipment,
        where: s.order_uuid == ^order_uuid,
        order_by: [desc: s.inserted_at, desc: s.uuid]
      )
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
      idempotency_key: idempotency_key(shipment),
      payer: if(pay_on_delivery?(order), do: :recipient, else: :shop),
      description: goods |> Enum.map_join(", ", &goods_label/1) |> ShipmentRequest.description(),
      declared_value: goods_total(goods),
      currency: order.currency
    }
  end

  # Unique per attempt and the same for the same attempt: a UUID (version 5
  # layout) from the SHA-1 of the shipment's uuid and its claim's time to the
  # microsecond, so it fits a carrier that takes only UUIDs.
  defp idempotency_key(%Shipment{submitted_at: %DateTime{} = at, uuid: uuid}) do
    <<head::binary-size(6), _version::4, mid::bits-size(12), _variant::2, tail::bits-size(62),
      _rest::binary>> = :crypto.hash(:sha, "#{uuid}:#{DateTime.to_unix(at, :microsecond)}")

    Ecto.UUID.load!(<<head::binary, 5::4, mid::bits, 2::2, tail::bits>>)
  end

  defp idempotency_key(_unclaimed), do: nil

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

  @doc """
  Whether a `creating` shipment has waited 10 minutes for its attempt's
  answer: the admin may then resolve it like an `unknown` one. The line is
  the one the lists and the resolutions draw (a cutoff to the second).
  """
  @spec stuck?(Shipment.t()) :: boolean()
  def stuck?(%Shipment{status: "creating", updated_at: %DateTime{} = updated_at}),
    do: DateTime.compare(updated_at, stuck_cutoff()) == :lt

  def stuck?(%Shipment{}), do: false

  @doc """
  Whether the carrier has a label for the shipment: it is `created`,
  `in_transit` or `ready_for_pickup`.
  """
  @spec printable?(Shipment.t()) :: boolean()
  def printable?(%Shipment{status: status}), do: status in @cancellable_statuses

  @doc """
  `value` trimmed when it is an `http` or `https` address with a host, at
  most #{@max_url_length} characters long, otherwise `nil`. A tracking link is stored and rendered only through it, so
  a `javascript:` or `data:` link never reaches a page.
  """
  @spec web_url(term()) :: String.t() | nil
  def web_url(value) when is_binary(value) do
    url = String.trim(value)

    case String.length(url) <= @max_url_length and URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if String.downcase(scheme) in ["http", "https"], do: url

      _other ->
        nil
    end
  end

  def web_url(_value), do: nil

  # -- the admin's lists -------------------------------------------------

  @doc """
  The statuses a shipment of `list_open/1` (`:open`) or
  `list_needs_attention/1` (`:needs_attention`) can have.
  """
  @spec section_statuses(:open | :needs_attention) :: [String.t()]
  def section_statuses(:open), do: @open_statuses
  def section_statuses(:needs_attention), do: @attention_statuses

  @doc "How many rows each of the admin's lists returns at most."
  @spec list_limit() :: pos_integer()
  def list_limit, do: @list_limit

  @doc """
  The paid orders waiting for a shipment, the oldest first (at most
  #{@list_limit}): their shipping method's provider can register shipments
  (`create_shipment/2`) and the order has no shipment, or only cancelled
  ones (the admin cancels one to register the order again). An order whose
  shipment failed is in `list_needs_attention/1` instead.

  `{order, method}` pairs. Options: `:provider`, a provider key.
  """
  @spec list_to_ship(keyword()) :: [{Order.t(), ShippingMethod.t()}]
  def list_to_ship(opts \\ []) do
    methods = shipment_methods(opts[:provider])

    if methods == %{} do
      []
    else
      from(o in to_ship_query(methods),
        order_by: [asc: o.inserted_at, asc: o.uuid],
        limit: @list_limit
      )
      |> repo().all()
      |> Enum.map(fn order -> {order, Map.fetch!(methods, order_method_uuid(order))} end)
    end
  end

  @doc """
  The live shipments that wait for nothing from the admin, the newest first
  (at most #{@list_limit}): `created`, `in_transit`, `ready_for_pickup`, and
  `creating` for less than 10 minutes, of an order that is neither cancelled
  nor refunded.

  `{shipment, order}` pairs. Options: `:provider`, a provider key; `:status`.
  """
  @spec list_open(keyword()) :: [{Shipment.t(), Order.t()}]
  def list_open(opts \\ []), do: list_shipments(open_query(opts))

  @doc """
  The shipments the admin has to resolve, the newest first (at most
  #{@list_limit}): `unknown` and `failed` ones, `creating` ones that have
  waited 10 minutes, and live ones of an order that has been cancelled or
  refunded since.

  `{shipment, order}` pairs. Options: `:provider`, a provider key; `:status`.
  """
  @spec list_needs_attention(keyword()) :: [{Shipment.t(), Order.t()}]
  def list_needs_attention(opts \\ []), do: list_shipments(attention_query(opts))

  @doc """
  How many rows `list_to_ship/1`, `list_open/1` and `list_needs_attention/1`
  have, without their limit. Takes the same options.
  """
  @spec count_sections(keyword()) :: %{
          to_ship: non_neg_integer(),
          open: non_neg_integer(),
          needs_attention: non_neg_integer()
        }
  def count_sections(opts \\ []) do
    methods = shipment_methods(opts[:provider])

    %{
      to_ship: if(methods == %{}, do: 0, else: count(to_ship_query(methods))),
      open: count(open_query(opts)),
      needs_attention: count(attention_query(opts))
    }
  end

  @doc """
  The providers that can register shipments (`create_shipment/2`), as
  `{key, label}` pairs.
  """
  @spec shipment_providers() :: [{String.t(), String.t()}]
  def shipment_providers do
    for provider <- Shipping.providers(),
        Shipping.supports?(provider, :create_shipment),
        do: {provider.key(), provider.label()}
  end

  # The shipping methods whose provider can register shipments, by uuid.
  defp shipment_methods(provider_key) do
    supported = shipment_providers() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    for method <- repo().all(ShippingMethod),
        key = MethodConfig.from_method(method).provider,
        MapSet.member?(supported, key),
        is_nil(provider_key) or key == provider_key,
        into: %{},
        do: {method.uuid, method}
  end

  defp to_ship_query(methods) do
    method_uuids = Map.keys(methods)

    from(o in Order,
      as: :order,
      where: o.status == "paid",
      where:
        fragment("?->>'shipping_method_uuid'", o.metadata) in type(
          ^method_uuids,
          {:array, :string}
        ),
      where:
        not exists(
          from(s in Shipment,
            where: s.order_uuid == parent_as(:order).uuid and s.status != "cancelled",
            select: 1
          )
        )
    )
  end

  defp order_method_uuid(order),
    do: order.metadata |> Codec.get(:shipping_method_uuid) |> Codec.string()

  defp open_query(opts) do
    cutoff = stuck_cutoff()

    from([s, o] in shipments_query(opts),
      where: s.status in ^@open_statuses,
      where: s.status != "creating" or s.updated_at >= ^cutoff,
      where: o.status not in ^@closed_order_statuses
    )
  end

  defp attention_query(opts) do
    cutoff = stuck_cutoff()

    from([s, o] in shipments_query(opts),
      where:
        s.status in ["unknown", "failed"] or
          (s.status == "creating" and s.updated_at < ^cutoff) or
          (s.status in ^Shipment.live_statuses() and o.status in ^@closed_order_statuses)
    )
  end

  defp shipments_query(opts) do
    query = from(s in Shipment, join: o in Order, on: o.uuid == s.order_uuid)

    query =
      case opts[:provider] do
        nil -> query
        provider -> from([s, _o] in query, where: s.provider == ^provider)
      end

    case opts[:status] do
      nil -> query
      status -> from([s, _o] in query, where: s.status == ^status)
    end
  end

  defp list_shipments(query) do
    from([s, o] in query,
      order_by: [desc: s.inserted_at, desc: s.uuid],
      limit: @list_limit,
      select: {s, o}
    )
    |> repo().all()
  end

  defp count(query), do: query |> exclude(:order_by) |> repo().aggregate(:count)

  defp stuck_cutoff,
    do:
      DateTime.utc_now()
      |> DateTime.add(-@stuck_after_seconds, :second)
      |> DateTime.truncate(:second)

  @doc """
  What `begin_shipment/2` would send for `order`, or `retry_shipment/2` for a
  `failed` shipment, before the admin corrects it: `:parcels` (`Parcel`s),
  `:recipient` (string keys), `:destination` (a `Destination`), the provider
  `:context` of the order's method and its `:service` (`nil` when the
  provider could not list its services).

  Options: `:context_opts`.
  """
  @spec shipment_draft(Order.t() | Shipment.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def shipment_draft(order_or_shipment, opts \\ [])

  def shipment_draft(%Order{} = order, opts) do
    with {:ok, ctx} <- order_context(order, opts) do
      data = sent_data(order, ctx, [])
      {:ok, draft(ctx, data.parcels, data.recipient, data.destination)}
    end
  end

  def shipment_draft(%Shipment{} = shipment, opts) do
    with %Order{} = order <- fetch_order(shipment.order_uuid) || {:error, :not_found},
         {:ok, ctx} <- order_context(order, opts) do
      {:ok, draft(ctx, shipment.parcels, shipment.recipient, shipment.destination)}
    end
  end

  defp draft(ctx, parcels, recipient, destination) do
    service =
      case service_of(ctx) do
        {:ok, service} -> service
        {:error, _reason} -> nil
      end

    %{
      context: ctx,
      service: service,
      parcels: Codec.list(parcels, &Parcel.from_map/1),
      recipient: Codec.string_map(recipient || %{}),
      destination: Destination.from_map(destination) || %Destination{}
    }
  end

  # -- labels ------------------------------------------------------------

  @doc """
  Whether `print_labels/2` would take the shipments `ids`: `:ok`, or the
  refusal it would answer about the ids and the shipments. Neither the
  carrier nor the connection is asked.
  """
  @spec check_labels([String.t()]) :: :ok | {:error, error()}
  def check_labels(ids) do
    with {:ok, uuids} <- label_uuids(ids),
         {:ok, _shipments} <- label_shipments(uuids),
         do: :ok
  end

  @doc """
  The labels of the shipments `ids` as one document from their carrier
  (`Shipping.print_labels/3`): `{:ok, %{content_type, body, shipments}}`.

  At most #{@max_labels} ids, each a UUID of a shipment the carrier has a
  label for (`printable?/1`), all of one provider, connection and environment (test or live).
  Refused with `:invalid_shipment_ids`, `:too_many_labels`, `:not_found`,
  `:label_unavailable`, `:mixed_label_providers` or `:labels_not_supported`;
  a carrier's error is `{:labels_failed, reason}`.

  Options: `:format` (`LabelOptions.formats/0`, `:a4` otherwise),
  `:context_opts`.
  """
  @spec print_labels([String.t()], keyword()) ::
          {:ok, %{content_type: String.t(), body: binary(), shipments: [Shipment.t()]}}
          | {:error, error()}
  def print_labels(ids, opts \\ []) do
    with {:ok, uuids} <- label_uuids(ids),
         {:ok, [first | _] = shipments} <- label_shipments(uuids),
         {:ok, ctx} <- shipment_context(first, opts),
         :ok <-
           if(Shipping.supports?(ctx, :print_labels),
             do: :ok,
             else: {:error, :labels_not_supported}
           ) do
      options = %LabelOptions{format: label_format(opts[:format])}

      case Shipping.print_labels(ctx, Enum.map(shipments, &shipment_ref/1), options) do
        {:ok, document} -> {:ok, Map.put(document, :shipments, shipments)}
        {:error, reason} -> {:error, {:labels_failed, reason}}
      end
    end
  end

  defp label_uuids(ids) when is_list(ids) do
    uuids = ids |> Enum.map(&uuid_or_nil/1) |> Enum.uniq()

    cond do
      uuids == [] or Enum.any?(uuids, &is_nil/1) -> {:error, :invalid_shipment_ids}
      length(uuids) > @max_labels -> {:error, :too_many_labels}
      true -> {:ok, uuids}
    end
  end

  defp label_uuids(_ids), do: {:error, :invalid_shipment_ids}

  defp label_shipments(uuids) do
    found =
      from(s in Shipment, where: s.uuid in ^uuids) |> repo().all() |> Map.new(&{&1.uuid, &1})

    shipments = Enum.map(uuids, &Map.get(found, &1))

    cond do
      Enum.any?(shipments, &is_nil/1) ->
        {:error, :not_found}

      not Enum.all?(shipments, &printable?/1) ->
        {:error, :label_unavailable}

      shipments |> Enum.uniq_by(&carrier_group/1) |> length() > 1 ->
        {:error, :mixed_label_providers}

      true ->
        {:ok, shipments}
    end
  end

  # One document is printed (and one tracking call made) through one
  # context, a shipment's of the group: the others must share its provider,
  # connection and environment.
  defp carrier_group(%Shipment{} = shipment) do
    environment = (shipment.context_snapshot || %{}) |> Codec.get(:environment) |> Codec.string()
    {shipment.provider, shipment.integration_uuid, environment}
  end

  defp label_format(format) do
    if format in LabelOptions.formats(), do: format, else: %LabelOptions{}.format
  end

  # -- registering ------------------------------------------------------

  @doc """
  Registers a shipment of a paid order: `begin_shipment/2`, then
  `submit_shipment/2`. Takes the options of both.
  """
  @spec register(Order.t() | String.t(), keyword()) :: {:ok, Shipment.t()} | {:error, error()}
  def register(order, opts \\ []) do
    refuse_transaction!()
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
    with :ok <- valid_corrections(opts),
         {:ok, order} <- fetch_paid_order(order),
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
    # The attempt runs in its own process: it would wait for the rows this
    # transaction holds while this transaction waits for it, and the carrier
    # call would sit inside the transaction.
    refuse_transaction!()

    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> attempt(uuid, opts) end)

    case Task.yield(task, :infinity) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("Shipment #{uuid}: the attempt crashed: #{Exception.format_exit(reason)}")
        {:error, :submit_crashed}
    end
  end

  defp refuse_transaction! do
    if repo().in_transaction?() do
      raise ArgumentError,
            "Shipments.submit_shipment/2 (and register/2) must not run inside a transaction"
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

        Logger.info("Shipment #{shipment.uuid}: " <> outcome_text(outcome))
        store_logged(shipment, outcome, actor_uuid)

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
  defp outcome_text({:ok, %ShipmentResult{} = result}) do
    "the carrier registered it, tracking number #{inspect(result.tracking_number)}, " <>
      "carrier reference #{inspect(result.carrier_ref)}"
  end

  defp outcome_text({:error, reason}),
    do: "the carrier call ended #{if(definite?(reason), do: "failed", else: "unknown")}"

  # The info line above is gone on a host that logs warnings and up; a write
  # that fails is logged again, as an error, with the answer it lost.
  defp store_logged(shipment, outcome, actor_uuid) do
    store_outcome(shipment, outcome, actor_uuid)
  rescue
    error ->
      log_lost(shipment, outcome, Exception.message(error))
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      log_lost(shipment, outcome, Exception.format_banner(kind, reason))
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp log_lost(shipment, outcome, why) do
    Logger.error(
      "Shipment #{shipment.uuid}: storing it failed (#{why}); " <> outcome_text(outcome)
    )
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
    with :ok <- valid_corrections(opts),
         %Shipment{status: "failed"} = shipment <- get_shipment(shipment.uuid) || :not_found,
         {:ok, order} <- fetch_paid_order(shipment.order_uuid),
         {:ok, ctx} <- order_context(order, opts),
         data = sent_data(order, ctx, previous_data(shipment, opts), shipment.recipient),
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

  Options: `:actor_uuid`, `:tracking_url` (a web address, `web_url/1`, or
  blank; anything else is `{:error, :invalid_tracking_url}`), `:carrier_ref`.
  """
  @spec enter_tracking_number(Shipment.t(), String.t(), keyword()) ::
          {:ok, Shipment.t()} | {:error, error()}
  def enter_tracking_number(%Shipment{} = shipment, tracking_number, opts \\ []) do
    url = opts |> Keyword.get(:tracking_url) |> Codec.string() |> blank_to_nil()

    case {tracking_number |> Codec.string() |> blank_to_nil(), url && web_url(url)} do
      {nil, _url} ->
        {:error, :tracking_number_required}

      {_number, nil} when not is_nil(url) ->
        {:error, :invalid_tracking_url}

      {number, web_url} ->
        changes = [
          error: nil,
          tracking_number: number,
          tracking_url: web_url,
          carrier_ref: opts |> Keyword.get(:carrier_ref) |> Codec.string() |> blank_to_nil()
        ]

        shipment
        |> resolve(@resolvable_statuses, true, "tracking_entered", "created", changes, opts)
        |> then(fn
          {:ok, stored} -> {:ok, created(stored)}
          error -> error
        end)
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

  @doc "Whether the order has been cancelled or refunded."
  @spec closed_order?(Order.t()) :: boolean()
  def closed_order?(%Order{status: status}), do: status in @closed_order_statuses

  @doc """
  Closes a `failed` shipment of an order that has been cancelled or refunded
  since: `cancelled`, locally (the carrier never registered it). Retrying it
  is refused (`:order_not_paid`), so without this it would wait for the admin
  for good. `{:error, :order_not_closed}` while the order is open.

  Options: `:actor_uuid`.
  """
  @spec close_shipment(Shipment.t(), keyword()) :: {:ok, Shipment.t()} | {:error, error()}
  def close_shipment(%Shipment{} = shipment, opts \\ []) do
    with %Shipment{} = shipment <- get_shipment(shipment.uuid) || {:error, :not_found},
         %Order{status: status} when status in @closed_order_statuses <-
           fetch_order(shipment.order_uuid) || {:error, :not_found} do
      resolve(shipment, ["failed"], false, "closed", "cancelled", [], opts)
    else
      %Order{} -> {:error, :order_not_closed}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Cancels a `created`, `in_transit` or `ready_for_pickup` shipment at the
  carrier (the provider's `cancel_shipment/2`), then records it `cancelled`.
  `{:error, :cancel_not_supported}` for a provider without the callback.
  A failure writes nothing: the carrier's refusal (a definite failure, see
  `Shipping.definite_failure?/1`) is `{:error, {:cancel_refused, text}}`, a
  call whose outcome is not known (a timeout, a crash, HTTP 5xx...) is
  `{:error, {:cancel_unconfirmed, text}}`; the text is masked like a stored
  error.

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
         :ok <- cancel_at_carrier(ctx, shipment) do
      resolve(shipment, @cancellable_statuses, false, "cancelled", "cancelled", [], opts)
    end
  end

  defp cancel_at_carrier(ctx, shipment) do
    case Shipping.cancel_shipment(ctx, shipment_ref(shipment)) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {cancel_error(reason), shipment |> masked(error_text(reason)) |> cut()}}
    end
  end

  # A definite failure is the carrier's no; a timeout, a crash or an ambiguous
  # status leaves open whether it cancelled.
  defp cancel_error(reason),
    do: if(Shipping.definite_failure?(reason), do: :cancel_refused, else: :cancel_unconfirmed)

  # -- tracking ----------------------------------------------------------

  @doc """
  Moves the shipments that have waited in `creating` for 10 minutes
  (`stuck?/1`) to `unknown`, with an event, each on condition that it is
  still `creating` and still that old. The admin resolves them like any
  `unknown` shipment; an attempt that answers later changes nothing
  (`submit_shipment/2`). Returns how many moved.
  """
  @spec sweep_stuck() :: non_neg_integer()
  def sweep_stuck do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(now, -@stuck_after_seconds, :second)

    {count, _} =
      from(s in Shipment, where: s.status == "creating" and s.updated_at < ^cutoff)
      |> append_event(event("swept", "unknown", nil, nil))
      |> repo().update_all(set: [status: "unknown", updated_at: now])

    count
  end

  @doc """
  One tracking pass: asks the carriers for the state of the shipments in
  `created`, `in_transit` or `ready_for_pickup` that were created less than
  #{@tracking_days} days ago and whose provider exports `track/2` (at most
  #{@track_limit}, those asked longest ago first), and stores what changed.

    * The shipments are grouped by provider, connection and environment.
      Each group is one `Shipping.track/2` call with all its references,
      through the context of a shipment of the group; the adapter decides
      how many carrier calls that makes (a carrier may take one per run).
      `track/2` must answer for every reference it is given; a shipment
      the answer says nothing about keeps its `last_tracked_at`, so it is
      among the first asked next time and a short answer cannot hold the
      others back. An error of one group (the carrier's, or no context to
      rebuild from the group's first shipment) is logged and leaves the
      other groups alone. The group's shipments are stamped, so a dead
      carrier does not hold the head of the queue either, and get a
      `tracking_failed` event when a run of failures starts
      (`tracking_failing_since/1`), a `tracking_resumed` one when the
      carrier answers again.
    * An update belongs to the shipment of its group with its tracking
      number or carrier reference.
    * A status never moves backwards: an update must rank above the
      current status (`created < in_transit < ready_for_pickup < delivered
      < returned`, the return leg above the outbound one, the carrier's
      `cancelled` with `returned`), and one with a time must also be newer
      than the last time stored. Of the updates that qualify the highest
      status counts, timed or not.
    * The write is conditional on the status the update was weighed
      against, and appends the event: the carrier's text masked, and its
      time.

  Options: `:context_opts`. Returns how many groups were asked, how many of
  them failed and how many shipments changed.
  """
  @spec track_shipments(keyword()) :: %{
          groups: non_neg_integer(),
          failed: non_neg_integer(),
          updated: non_neg_integer()
        }
  def track_shipments(opts \\ []) do
    results =
      tracked_shipments()
      |> Enum.group_by(&carrier_group/1)
      |> Enum.map(fn {_group, shipments} -> track_group(shipments, opts) end)

    %{
      groups: length(results),
      failed: Enum.count(results, &(&1 == :error)),
      updated: results |> Enum.filter(&is_integer/1) |> Enum.sum()
    }
  end

  defp tracked_shipments do
    case tracking_providers() do
      [] ->
        []

      keys ->
        cutoff =
          DateTime.utc_now()
          |> DateTime.add(-@tracking_days * 86_400, :second)
          |> DateTime.truncate(:second)

        from(s in Shipment,
          where: s.status in ^@cancellable_statuses,
          where: s.provider in ^keys,
          where: s.inserted_at >= ^cutoff,
          order_by: [asc_nulls_first: s.last_tracked_at, asc: s.inserted_at, asc: s.uuid],
          limit: @track_limit
        )
        |> repo().all()
    end
  end

  defp tracking_providers do
    for provider <- Shipping.providers(),
        Shipping.supports?(provider, :track),
        do: provider.key()
  end

  defp track_group([first | _] = shipments, opts) do
    answer =
      with {:ok, ctx} <- group_context(shipments, opts),
           do: Shipping.track(ctx, Enum.map(shipments, &shipment_ref/1))

    case answer do
      {:ok, updates} ->
        covered =
          Enum.filter(shipments, fn shipment -> Enum.any?(updates, &about?(&1, shipment)) end)

        stamp_tracked(covered)
        Enum.each(covered, &note_tracking(&1, :resumed, nil))
        Enum.count(covered, &(track_one(&1, updates) == :updated))

      {:error, reason} ->
        stamp_tracked(shipments)
        Enum.each(shipments, &note_tracking(&1, :failed, track_error_text(reason)))

        Logger.warning(
          "Shipment tracking: #{first.provider} (#{length(shipments)} shipments) " <>
            "failed: #{track_error_text(reason)}"
        )

        :error
    end
  rescue
    error ->
      Logger.error(
        "Shipment tracking: #{first.provider} (#{length(shipments)} shipments) " <>
          "raised #{inspect(error.__struct__)}"
      )

      :error
  end

  # The shipments of a group share the provider, the connection and its
  # environment, so the first one's context serves them all; when it cannot
  # be rebuilt (the connection changed or is gone) the group fails, rather
  # than rebuilding one context per shipment of a dead connection.
  defp group_context([first | _], opts), do: shipment_context(first, opts)

  # One `tracking_failed` event when a run of failures starts (its tag only,
  # never the carrier's text), one `tracking_resumed` when an answer comes
  # again: a carrier that keeps failing does not push the shipment's history
  # out of its last 50 events.
  defp note_tracking(shipment, kind, tag) do
    case {kind, tracking_failure(shipment)} do
      {:failed, nil} -> append_tracking_event(shipment, "tracking_failed", tag)
      {:resumed, %{}} -> append_tracking_event(shipment, "tracking_resumed", nil)
      _no_change -> :ok
    end
  end

  defp append_tracking_event(shipment, action, message) do
    event = event(action, shipment.status, nil, shipment |> masked(message) |> cut())
    compare_and_set(shipment.uuid, [shipment.status], [], event: event)
    :ok
  end

  # The open failure: the `tracking_failed` event after which no answer came
  # (a `tracking_resumed` or a `tracked` event), or `nil`.
  defp tracking_failure(%Shipment{events: events}) do
    events
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find(&(is_map(&1) and &1["action"] in ~w(tracking_failed tracking_resumed tracked)))
    |> case do
      %{"action" => "tracking_failed"} = failed -> failed
      _answered -> nil
    end
  end

  @doc """
  Since when the carrier's tracking of the shipment has been failing (its
  error, or a connection that cannot be rebuilt), or `nil` while it answers.
  Read from the shipment's events: the run of failures starts with a
  `tracking_failed` event and ends with the next answer.
  """
  @spec tracking_failing_since(Shipment.t()) :: DateTime.t() | nil
  def tracking_failing_since(%Shipment{} = shipment) do
    with %{"at" => at} when is_binary(at) <- tracking_failure(shipment),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(at) do
      datetime
    else
      _none -> nil
    end
  end

  defp stamp_tracked(shipments) do
    uuids = Enum.map(shipments, & &1.uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    repo().update_all(from(s in Shipment, where: s.uuid in ^uuids),
      set: [last_tracked_at: now]
    )
  end

  # The log keeps the shape of a carrier's error, never its text: that may
  # quote a recipient.
  defp track_error_text({:http_status, status}), do: "HTTP #{status}"
  defp track_error_text({:http_status, status, _detail}), do: "HTTP #{status}"
  defp track_error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp track_error_text({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp track_error_text(_reason), do: "error"

  # A shipment whose write raises (its e-mail cannot be queued, say) is
  # logged and left as it was; the rest of the group is still stored.
  defp track_one(shipment, updates) do
    case best_update(shipment, updates) do
      %TrackingUpdate{} = update ->
        store_tracking(shipment, Atom.to_string(update.status), update)

      nil ->
        :unchanged
    end
  rescue
    error ->
      Logger.error(
        "Shipment #{shipment.uuid}: storing its tracking raised #{inspect(error.__struct__)}"
      )

      :error
  end

  # Of the shipment's updates that would move it forward, the highest status,
  # and of two with the same status the timed one, then the later one.
  defp best_update(shipment, updates) do
    last = last_occurred_at(shipment)

    updates
    |> Enum.filter(
      &(about?(&1, shipment) and &1.status in TrackingUpdate.statuses() and
          forward?(shipment, &1, last))
    )
    |> Enum.max_by(&{rank(&1.status), unix(&1.occurred_at)}, fn -> nil end)
  end

  defp unix(%DateTime{} = at), do: {1, DateTime.to_unix(at, :microsecond)}
  defp unix(_no_time), do: {0, 0}

  defp about?(%TrackingUpdate{} = update, shipment) do
    same?(update.tracking_number, shipment.tracking_number) or
      same?(update.carrier_ref, shipment.carrier_ref)
  end

  defp about?(_other, _shipment), do: false

  defp same?(value, stored), do: filled?(value) and value == stored

  # Forward means a higher status (the return leg ranks above the outbound
  # one); an update with a time must also be newer than the last one stored.
  defp forward?(shipment, %TrackingUpdate{status: status, occurred_at: at}, last) do
    rank(status) > rank(shipment.status) and
      (not match?(%DateTime{}, at) or not match?(%DateTime{}, last) or
         DateTime.compare(at, last) == :gt)
  end

  defp rank(status) when is_atom(status), do: rank(Atom.to_string(status))
  defp rank(status), do: Map.get(@rank, status, -1)

  # The carrier's time of the last update stored, kept on its event.
  defp last_occurred_at(%Shipment{events: events}) do
    events
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"action" => "tracked", "occurred_at" => at} when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, datetime, _offset} -> [datetime]
          {:error, _reason} -> []
        end

      _other ->
        []
    end)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # The status and its e-mail commit together: an e-mail that cannot be
  # queued leaves the status for the next run to find again.
  defp store_tracking(shipment, status, update) do
    message = shipment |> masked(Codec.string(update.description)) |> cut()

    tracked =
      "tracked"
      |> event(status, nil, message)
      |> Map.put("occurred_at", update.occurred_at && DateTime.to_iso8601(update.occurred_at))

    {:ok, result} = repo().transaction(fn -> write_tracking(shipment, status, tracked) end)
    result
  end

  defp write_tracking(shipment, status, tracked) do
    case compare_and_set(shipment.uuid, [shipment.status], [status: status], event: tracked) do
      {:ok, stored} ->
        if status in @shipped_statuses, do: OrderEmails.shipment_shipped(stored)
        :updated

      {:error, :shipment_changed} ->
        :unchanged
    end
  end

  # A provider without `track/2` never reports the parcel moving: its
  # shipment is shipped once the carrier has it. The answer is stored
  # already, and an e-mail that cannot be queued must not lose it.
  defp created(%Shipment{status: "created"} = shipment) do
    if shipped?(shipment), do: queue_shipped_email(shipment)
    shipment
  end

  defp created(shipment), do: shipment

  defp queue_shipped_email(shipment) do
    OrderEmails.shipment_shipped(shipment)
  rescue
    error -> log_unqueued(shipment, Exception.message(error))
  catch
    kind, reason -> log_unqueued(shipment, Exception.format_banner(kind, reason))
  end

  defp log_unqueued(shipment, why),
    do: Logger.error("Shipment #{shipment.uuid}: the buyer's e-mail was not queued (#{why})")

  # -- the buyer's view --------------------------------------------------

  @doc """
  Whether the buyer is told the shipment is on its way: it is `in_transit`,
  `ready_for_pickup` or `delivered`, or `created` with a provider that does
  not track (`track/2`), which never reports the parcel moving.
  """
  @spec shipped?(Shipment.t()) :: boolean()
  def shipped?(%Shipment{status: status}) when status in @shipped_statuses, do: true
  def shipped?(%Shipment{status: "created", provider: key}), do: not tracked_provider?(key)
  def shipped?(%Shipment{}), do: false

  defp tracked_provider?(key) do
    case Shipping.provider(key) do
      {:ok, provider} -> Shipping.supports?(provider, :track)
      :error -> false
    end
  end

  @doc """
  The shipments the buyer is shown, of each of `order_uuids`, the newest
  first: `created` and later (`in_transit`, `ready_for_pickup`,
  `delivered`, `returned`). One query for all the orders; an order without
  one has no key.
  """
  @spec buyer_shipments([String.t()]) :: %{String.t() => [Shipment.t()]}
  def buyer_shipments(order_uuids) when is_list(order_uuids) do
    case order_uuids |> Enum.map(&uuid_or_nil/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        from(s in Shipment,
          where: s.order_uuid in ^uuids and s.status in ^@buyer_statuses,
          order_by: [desc: s.inserted_at, desc: s.uuid]
        )
        |> repo().all()
        |> Enum.group_by(& &1.order_uuid)
    end
  end

  @doc """
  The order status the buyer reads (for `Web.StatusLabels.order/1`), given
  the order's shipments from `buyer_shipments/1`: while the order is `paid`
  or `processing`, `"delivered"` when its newest shipment is delivered and
  `"shipped"` when it is `shipped?/1`; the order's own status otherwise.
  """
  @spec buyer_order_status(%{:status => String.t(), optional(atom()) => any()}, [Shipment.t()]) ::
          String.t()
  def buyer_order_status(%{status: status}, shipments) when status in ["paid", "processing"] do
    case shipments do
      [%Shipment{status: "delivered"} | _] -> "delivered"
      [%Shipment{} = newest | _] -> if shipped?(newest), do: "shipped", else: status
      _none -> status
    end
  end

  def buyer_order_status(%{status: status}, _shipments), do: status

  @doc """
  Who carries the shipment, for the buyer: the carrier behind an aggregator
  (`carrier_label`), else the provider's label, else its key.
  """
  @spec carrier_name(Shipment.t()) :: String.t()
  def carrier_name(%Shipment{carrier_label: label, provider: key}) do
    if filled?(label) do
      String.trim(label)
    else
      case Shipping.provider(key) do
        {:ok, provider} -> provider.label()
        :error -> key || ""
      end
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

  # `recipient` is what a correction applies to: the order's buyer, or what
  # the shipment sent last time.
  defp sent_data(order, ctx, opts, recipient \\ nil) do
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
        (recipient || billing_recipient(order.billing_snapshot))
        |> corrected(Keyword.get(opts, :recipient))
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

  # A company buyer is sent as its company and its contact person; a company
  # with no person named is addressed by the company name.
  defp billing_recipient(snapshot) when is_map(snapshot) do
    person =
      [Codec.get(snapshot, :first_name), Codec.get(snapshot, :last_name)]
      |> Enum.filter(&filled?/1)
      |> Enum.join(" ")

    company =
      if Codec.get(snapshot, :type) == "company" and filled?(Codec.get(snapshot, :company_name)),
        do: Codec.get(snapshot, :company_name)

    %{
      name: if(person == "", do: company, else: person),
      company: company,
      email: Codec.get(snapshot, :email),
      phone: Codec.get(snapshot, :phone)
    }
  end

  defp billing_recipient(_snapshot), do: %{}

  defp valid_corrections(opts) do
    case Keyword.get(opts, :recipient) do
      recipient when is_nil(recipient) or is_map(recipient) -> :ok
      _other -> {:error, :invalid_recipient}
    end
  end

  # A correction changes the fields it names (a blank one clears it) and
  # leaves the others. A corrected phone is the number as typed now.
  defp corrected(recipient, nil), do: recipient

  defp corrected(recipient, correction) when is_map(correction) do
    given =
      for key <- @recipient_keys,
          Map.has_key?(correction, key) or Map.has_key?(correction, Atom.to_string(key)),
          into: %{},
          do: {key, Codec.get(correction, key)}

    given =
      if Map.has_key?(given, :phone) and not Map.has_key?(given, :raw_phone),
        do: Map.put(given, :raw_phone, nil),
        else: given

    recipient |> ShipmentRequest.recipient() |> Map.merge(given)
  end

  # The number as it was typed is kept beside the normalised one: a stored
  # recipient (a retry) carries both, a new one only the typed `phone`.
  defp recipient_map(recipient, country) do
    %{name: name, company: company, email: email, phone: phone, raw_phone: raw} =
      ShipmentRequest.recipient(recipient)

    raw = raw || phone

    %{
      "name" => name,
      "company" => company,
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
      tracking_url: carrier_tracking_url(shipment, result.tracking_url),
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
        {:ok, created(stored)}

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

  # The link is rendered to the admin and, later, to the buyer: a carrier's
  # answer that is not a web address is not stored, and not quoted in the log.
  defp carrier_tracking_url(_shipment, nil), do: nil

  defp carrier_tracking_url(shipment, url) do
    case web_url(url) do
      nil ->
        Logger.warning(
          "Shipment #{shipment.uuid}: the carrier's tracking link is not a web " <>
            "address; not stored"
        )

        nil

      web_url ->
        web_url
    end
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

  # A detail the carrier gave as data (its JSON errors) is shown as JSON, so
  # the admin sees what to correct.
  defp error_text({:http_status, status, nil}), do: "HTTP #{status}"
  defp error_text({:http_status, status, detail}), do: "HTTP #{status}: #{detail_text(detail)}"

  defp error_text({:provider_crashed, message}) when is_binary(message),
    do: "crashed: " <> message

  defp error_text({:bad_return, shape}) when is_binary(shape), do: "unexpected answer: " <> shape
  defp error_text(%{__exception__: true} = error), do: Exception.message(error)
  defp error_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_text(reason), do: inspect(reason, limit: 20, printable_limit: @error_max)

  defp detail_text(detail) do
    case Jason.encode(detail) do
      {:ok, json} -> json
      {:error, _not_json} -> inspect(detail, limit: 20, printable_limit: @error_max)
    end
  end

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
