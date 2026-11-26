defmodule PhoenixKitEcommerce.Web.Shipments do
  @moduledoc """
  The Shipments admin page (`shop.manage_shipments`, read included: the rows
  carry the recipients' contact details).

  Three sections (`PhoenixKitEcommerce.Shipments`):

    * **To ship** - paid orders whose method's carrier can register
      shipments and that have none but cancelled ones (`list_to_ship/1`).
      One order is registered at a time: alone, after the admin has looked
      at (and may have corrected) the parcels, the recipient and the
      destination, or as a batch of at most 50 ticked orders, each with the
      order's own data.
    * **Open** - live shipments that wait for nothing from the admin
      (`list_open/1`), with their labels.
    * **Needs attention** - `unknown`, `failed` and stuck `creating`
      shipments, and live ones of a cancelled or refunded order
      (`list_needs_attention/1`), with the actions that resolve them (a
      failed one of such an order is closed locally, `close_shipment/2`).

  The carrier is called from `start_async`: `register/2` (or
  `retry_shipment/2` and `submit_shipment/2`) and `cancel_shipment/2`. One such
  call runs at a time; the page shows which and, for a batch, how far it got,
  and lists the outcome of each. The call and its Activity entry run in a
  process of their own under `Shipments.TaskSupervisor`, so closing the page
  loses neither the carrier's answer nor the entry.

  Activity is logged here on every change (no recipient data); the labels'
  print is logged by `Web.ShipmentLabelsController`.
  """

  use PhoenixKitEcommerce.Web, :live_view

  import PhoenixKitWeb.Components.Core.NavTabs

  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.{Activity, Errors, Shipment, Shipments}
  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{CartQuote, Codec, Destination, Parcel}
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Web.Components.ShipmentDestinationEditor
  alias PhoenixKitEcommerce.Web.StatusLabels

  @sections ~w(to_ship open needs_attention)
  @max_batch 50
  @max_parcels 20
  @max_dimension 10_000_000
  @recipient_fields ~w(name company email phone)
  @field_length 255

  @impl true
  def mount(params, session, socket) do
    Authz.authorize_mount(socket, :manage_shipments, fn -> do_mount(params, session, socket) end)
  end

  defp do_mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign_shop_trail(gettext("Shipments"))
     |> assign(
       section: "to_ship",
       provider: nil,
       status: nil,
       providers: Shipments.shipment_providers(),
       counts: %{to_ship: 0, open: 0, needs_attention: 0},
       section_count: 0,
       selected_orders: [],
       selected_shipments: [],
       labels_check: nil,
       editor: nil,
       editor_loading: false,
       tracking: nil,
       confirm: nil,
       running: nil,
       batch: nil,
       outcomes: []
     )
     |> stream_configure(:orders, dom_id: fn {order, _method} -> "to-ship-#{order.uuid}" end)
     |> stream_configure(:shipments,
       dom_id: fn {shipment, _order} -> "shipment-#{shipment.uuid}" end
     )
     |> stream(:orders, [])
     |> stream(:shipments, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The mount guard navigates away, but handle_params still runs for this
    # request: nothing is read without the key.
    if Authz.can?(socket, :manage_shipments) do
      provider_keys = Enum.map(socket.assigns.providers, &elem(&1, 0))

      section = if(params["section"] in @sections, do: params["section"], else: "to_ship")

      {:noreply,
       socket
       |> assign(
         section: section,
         provider: if(params["provider"] in provider_keys, do: params["provider"]),
         status: if(params["status"] in section_statuses(section), do: params["status"])
       )
       |> load()}
    else
      {:noreply, socket}
    end
  end

  # Every read of the lists goes through here: none without the key (a
  # scope can lose it while the page is open, a carrier call ending later).
  defp load(socket) do
    if Authz.can?(socket, :manage_shipments), do: read_lists(socket), else: socket
  end

  defp read_lists(socket) do
    %{section: section, provider: provider, status: status} = socket.assigns
    opts = [provider: provider, status: status]
    # Tab badges reflect the carrier filter only: a status filter belongs to
    # the active section and must not zero out another tab's badge.
    counts = Shipments.count_sections(provider: provider)

    section_count =
      if status && section in ["open", "needs_attention"] do
        Shipments.count_sections(opts) |> section_count(section)
      else
        section_count(counts, section)
      end

    # The rows are streamed anew, unticked.
    socket =
      assign(socket,
        counts: counts,
        section_count: section_count,
        selected_orders: [],
        selected_shipments: [],
        labels_check: nil
      )

    case section do
      "to_ship" ->
        stream(socket, :orders, Shipments.list_to_ship(provider: provider), reset: true)

      "open" ->
        stream(socket, :shipments, Shipments.list_open(opts), reset: true)

      "needs_attention" ->
        stream(socket, :shipments, Shipments.list_needs_attention(opts), reset: true)
    end
  end

  defp url(assigns, overrides) do
    query =
      [
        section: Keyword.get(overrides, :section, assigns.section),
        provider: Keyword.get(overrides, :provider, assigns.provider),
        status: Keyword.get(overrides, :status, assigns.status)
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    if query == "",
      do: Routes.path("/admin/shop/shipments"),
      else: Routes.path("/admin/shop/shipments?" <> query)
  end

  # The label route is outside the admin segment and the locale prefix
  # (`Web.Routes.generate/1`).
  defp labels_path(uuids),
    do: Routes.path("/shop-shipments/labels?ids=" <> Enum.join(uuids, ","), locale: :none)

  # -- events ---------------------------------------------------------------

  @impl true
  def handle_event(event, params, socket) do
    Authz.authorize(socket, :manage_shipments, fn -> gated_event(event, params, socket) end)
  end

  defp gated_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to: url(socket.assigns, provider: params["provider"], status: params["status"])
     )}
  end

  defp gated_event("select_orders", params, socket),
    do: {:noreply, assign(socket, selected_orders: uuids_param(params["order_uuids"]))}

  # The label route's own checks, so a selection it would refuse gets the
  # reason instead of a link.
  defp gated_event("select_shipments", params, socket) do
    selected = uuids_param(params["shipment_uuids"])
    check = if selected != [], do: Shipments.check_labels(selected)
    {:noreply, assign(socket, selected_shipments: selected, labels_check: check)}
  end

  defp gated_event("open_register", %{"uuid" => uuid}, socket) do
    open_editor(socket, fn ->
      with %Order{} = order <-
             PhoenixKitBilling.get_order(uuid, preload: []) || {:error, :not_found},
           {:ok, draft} <- Shipments.shipment_draft(order),
           do: {:ok, editor(:register, uuid, order, draft)}
    end)
  end

  defp gated_event("open_retry", %{"uuid" => uuid}, socket) do
    open_editor(socket, fn ->
      with %Shipment{status: "failed"} = shipment <-
             Shipments.get_shipment(uuid) || {:error, :not_found},
           %Order{} = order <-
             PhoenixKitBilling.get_order(shipment.order_uuid, preload: []) ||
               {:error, :not_found},
           {:ok, draft} <- Shipments.shipment_draft(shipment) do
        {:ok, editor(:retry, uuid, order, draft)}
      else
        %Shipment{} -> {:error, :shipment_changed}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp gated_event("close_editor", _params, socket) do
    socket = if socket.assigns.editor_loading, do: cancel_async(socket, :draft), else: socket
    {:noreply, assign(socket, editor: nil, editor_loading: false)}
  end

  defp gated_event("editor_change", params, %{assigns: %{editor: %{} = editor}} = socket) do
    {:noreply, assign(socket, editor: take_form(editor, params))}
  end

  defp gated_event("add_parcel", _params, %{assigns: %{editor: %{} = editor}} = socket) do
    parcels =
      if length(editor.parcels) < @max_parcels,
        do: editor.parcels ++ [parcel_form(%Parcel{})],
        else: editor.parcels

    {:noreply, assign(socket, editor: %{editor | parcels: parcels})}
  end

  defp gated_event(
         "remove_parcel",
         %{"index" => index},
         %{assigns: %{editor: %{} = editor}} = socket
       ) do
    parcels =
      case Integer.parse(to_string(index)) do
        {i, ""} when length(editor.parcels) > 1 -> List.delete_at(editor.parcels, i)
        _ -> editor.parcels
      end

    {:noreply, assign(socket, editor: %{editor | parcels: parcels})}
  end

  defp gated_event("submit_editor", params, %{assigns: %{editor: %{} = editor}} = socket) do
    editor = take_form(editor, params)

    with :ok <- idle(socket),
         {:ok, parcels} <- parse_parcels(editor.parcels) do
      corrections = [
        actor_uuid: Activity.actor_uuid(socket),
        parcels: parcels,
        recipient: recipient_correction(editor),
        destination: editor.destination
      ]

      {:noreply,
       socket
       |> assign(editor: nil)
       |> run(editor.kind, editor.uuid, editor.order_number, corrections)}
    else
      {:error, :busy} -> {:noreply, put_flash(socket, :error, busy_message())}
      {:error, message} -> {:noreply, assign(socket, editor: %{editor | error: message})}
    end
  end

  defp gated_event("register_selected", _params, socket) do
    case {idle(socket), socket.assigns.selected_orders} do
      {{:error, :busy}, _selected} ->
        {:noreply, put_flash(socket, :error, busy_message())}

      {:ok, []} ->
        {:noreply, socket}

      {:ok, selected} when length(selected) > @max_batch ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("At most %{count} orders can be registered at once.", count: @max_batch)
         )}

      {:ok, [first | rest] = selected} ->
        {:noreply,
         socket
         |> assign(batch: %{queue: rest, total: length(selected), done: 0}, outcomes: [])
         |> run(:register, first, nil, actor_uuid: Activity.actor_uuid(socket))}
    end
  end

  defp gated_event("close", %{"uuid" => uuid}, socket) do
    resolve(socket, uuid, "shop.shipment_closed", &Shipments.close_shipment(&1, &2))
  end

  defp gated_event("mark_failed", %{"uuid" => uuid}, socket) do
    resolve(socket, uuid, "shop.shipment_marked_failed", &Shipments.mark_failed(&1, &2))
  end

  defp gated_event("open_tracking", %{"uuid" => uuid}, socket) do
    case Shipments.get_shipment(uuid) do
      %Shipment{} = shipment ->
        {:noreply,
         assign(socket,
           tracking: %{shipment: shipment, tracking_number: "", tracking_url: "", error: nil}
         )}

      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:not_found))}
    end
  end

  defp gated_event("close_tracking", _params, socket),
    do: {:noreply, assign(socket, tracking: nil)}

  defp gated_event(
         "submit_tracking",
         %{"tracking" => %{} = form},
         %{assigns: %{tracking: %{} = tracking}} = socket
       ) do
    actor = Activity.actor_uuid(socket)

    case Shipments.enter_tracking_number(tracking.shipment, form["tracking_number"],
           actor_uuid: actor,
           tracking_url: form["tracking_url"]
         ) do
      {:ok, shipment} ->
        log(actor(socket), "shop.shipment_tracking_entered", shipment)

        {:noreply,
         socket
         |> assign(tracking: nil)
         |> put_flash(:info, gettext("The tracking number is recorded."))
         |> load()}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           tracking: %{
             tracking
             | tracking_number: text(form["tracking_number"]) || "",
               tracking_url: tracking_url_text(form["tracking_url"]),
               error: Errors.message(reason)
           }
         )}
    end
  end

  defp gated_event("confirm", %{"action" => action, "uuid" => uuid}, socket)
       when action in ["cancel", "cancelled_at_carrier"] do
    case Shipments.get_shipment(uuid) do
      %Shipment{} = shipment ->
        {:noreply, assign(socket, confirm: %{action: action, shipment: shipment})}

      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:not_found))}
    end
  end

  defp gated_event("close_confirm", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  defp gated_event(
         "confirmed",
         _params,
         %{assigns: %{confirm: %{action: "cancel", shipment: shipment}}} = socket
       ) do
    case idle(socket) do
      :ok ->
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> run(:cancel, shipment.uuid, nil, actor_uuid: Activity.actor_uuid(socket))}

      {:error, :busy} ->
        {:noreply, socket |> assign(confirm: nil) |> put_flash(:error, busy_message())}
    end
  end

  defp gated_event(
         "confirmed",
         _params,
         %{assigns: %{confirm: %{action: "cancelled_at_carrier", shipment: shipment}}} = socket
       ) do
    socket = assign(socket, confirm: nil)

    resolve(
      socket,
      shipment.uuid,
      "shop.shipment_cancelled_at_carrier",
      &Shipments.mark_cancelled_at_carrier(&1, &2)
    )
  end

  defp gated_event("dismiss_outcomes", _params, socket),
    do: {:noreply, assign(socket, outcomes: [])}

  defp gated_event(_event, _params, socket), do: {:noreply, socket}

  # The draft asks the carrier for its services, which may be slow: the
  # editor opens at once and fills in when they arrive.
  defp open_editor(socket, load) do
    case idle(socket) do
      :ok ->
        {:noreply,
         socket |> assign(editor: nil, editor_loading: true) |> start_async(:draft, load)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, busy_message())}
    end
  end

  defp idle(%{assigns: %{running: nil}}), do: :ok
  defp idle(_socket), do: {:error, :busy}

  defp busy_message, do: gettext("Wait until the carrier has answered the current request.")

  # Only UUIDs: the ticked values end up in the labels link.
  defp uuids_param(list) when is_list(list) do
    list
    |> Enum.flat_map(fn value ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp uuids_param(_other), do: []

  # A local resolution: no carrier call.
  defp resolve(socket, uuid, action, fun) do
    with %Shipment{} = shipment <- Shipments.get_shipment(uuid) || {:error, :not_found},
         {:ok, shipment} <- fun.(shipment, actor_uuid: Activity.actor_uuid(socket)) do
      log(actor(socket), action, shipment)

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("Shipment of order %{number}: %{status}",
           number: order_number(shipment),
           status: StatusLabels.shipment(shipment.status)
         )
       )
       |> load()}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  # -- carrier calls ----------------------------------------------------------

  defp run(socket, :register, order_uuid, number, opts) do
    running = %{kind: :register, uuid: order_uuid, number: number || order_number_of(order_uuid)}
    call(socket, running, fn -> Shipments.register(order_uuid, opts) end)
  end

  defp run(socket, :retry, shipment_uuid, number, opts) do
    call(socket, %{kind: :retry, uuid: shipment_uuid, number: number}, fn ->
      with {:ok, shipment} <- Shipments.retry_shipment(%Shipment{uuid: shipment_uuid}, opts),
           do: Shipments.submit_shipment(shipment, opts)
    end)
  end

  defp run(socket, :cancel, shipment_uuid, _number, opts) do
    running = %{
      kind: :cancel,
      uuid: shipment_uuid,
      number: order_number_of_shipment(shipment_uuid)
    }

    call(socket, running, fn ->
      Shipments.cancel_shipment(%Shipment{uuid: shipment_uuid}, opts)
    end)
  end

  # The carrier call and its Activity entry run in a process of their own
  # (under `Shipments.TaskSupervisor`), which the async task only waits for:
  # an admin who closes the tab while the carrier is answering still leaves
  # the entry behind.
  defp call(socket, %{kind: kind} = running, work) do
    actor = actor(socket)

    socket
    |> assign(running: running)
    |> start_async(kind, fn ->
      task =
        Task.Supervisor.async_nolink(PhoenixKitEcommerce.Shipments.TaskSupervisor, fn ->
          logged(actor, kind, work.())
        end)

      case Task.yield(task, :infinity) do
        {:ok, result} -> result
        {:exit, reason} -> exit(reason)
      end
    end)
  end

  defp logged(actor, kind, {:ok, %Shipment{} = shipment} = result) do
    log(actor, action(kind), shipment)
    result
  end

  defp logged(_actor, _kind, result), do: result

  # Closing the editor while it loads cancels the draft: neither the
  # cancellation nor a draft that was already on its way opens anything.
  @impl true
  def handle_async(:draft, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:draft, _result, %{assigns: %{editor_loading: false}} = socket),
    do: {:noreply, socket}

  def handle_async(:draft, result, socket) do
    socket = assign(socket, editor_loading: false)

    case result do
      {:ok, {:ok, editor}} ->
        {:noreply, assign(socket, editor: editor)}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}

      {:exit, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("The carrier did not answer. Please try again."))}
    end
  end

  def handle_async(kind, result, socket) when kind in [:register, :retry, :cancel] do
    running = socket.assigns.running
    result = carrier_result(kind, result)

    socket
    |> assign(running: nil, outcomes: socket.assigns.outcomes ++ [outcome(running, result)])
    |> next_in_batch()
    |> then(&{:noreply, &1})
  end

  defp carrier_result(_kind, {:ok, {:ok, %Shipment{}} = ok}), do: ok
  defp carrier_result(_kind, {:ok, {:error, _reason} = error}), do: error

  # The task died (the shipment attempt itself is not linked to it): what the
  # carrier did is not known.
  defp carrier_result(:cancel, {:exit, _reason}),
    do: {:error, {:cancel_unconfirmed, "interrupted"}}

  defp carrier_result(_kind, {:exit, _reason}), do: {:error, :submit_crashed}

  defp action(:register), do: "shop.shipment_created"
  defp action(:retry), do: "shop.shipment_retried"
  defp action(:cancel), do: "shop.shipment_cancelled"

  # Each order of a batch is a carrier call of its own: a key taken away
  # meanwhile stops the batch.
  defp next_in_batch(%{assigns: %{batch: %{queue: [next | rest]} = batch}} = socket) do
    if Authz.can?(socket, :manage_shipments) do
      socket
      |> assign(batch: %{batch | queue: rest, done: batch.done + 1})
      |> run(:register, next, nil, actor_uuid: Activity.actor_uuid(socket))
    else
      socket |> assign(batch: nil) |> Authz.deny()
    end
  end

  defp next_in_batch(%{assigns: %{batch: %{}}} = socket),
    do: socket |> assign(batch: nil) |> load()

  defp next_in_batch(socket), do: load(socket)

  defp outcome(running, {:ok, %Shipment{} = shipment}) do
    %{
      id: "#{running.kind}-#{running.uuid}-#{System.unique_integer([:positive])}",
      number: running.number,
      tone: tone(shipment.status),
      text: outcome_text(shipment)
    }
  end

  defp outcome(running, {:error, reason}) do
    %{
      id: "#{running.kind}-#{running.uuid}-#{System.unique_integer([:positive])}",
      number: running.number,
      tone: :error,
      text: Errors.message(reason)
    }
  end

  defp tone(status) when status in ["created", "cancelled"], do: :success
  defp tone("unknown"), do: :warning
  defp tone(_status), do: :error

  defp outcome_text(%Shipment{status: "created", tracking_number: number}) when is_binary(number),
    do: gettext("Registered, tracking number %{number}", number: number)

  defp outcome_text(%Shipment{status: "failed", error: error}) when is_binary(error),
    do: gettext("Failed: %{error}", error: error)

  defp outcome_text(%Shipment{status: "unknown"}),
    do:
      gettext(
        "The carrier's answer is not known. Check the carrier's portal, then enter the tracking number or mark it failed."
      )

  defp outcome_text(%Shipment{status: status}), do: StatusLabels.shipment(status)

  defp actor(socket), do: %{uuid: Activity.actor_uuid(socket), role: Activity.actor_role(socket)}

  defp log(%{uuid: uuid, role: role}, action, %Shipment{} = shipment) do
    Activity.log(action,
      actor_uuid: uuid,
      actor_role: role,
      resource_type: "shipment",
      resource_uuid: shipment.uuid,
      target_uuid: shipment.order_uuid,
      metadata: %{"status" => shipment.status, "provider" => shipment.provider}
    )
  end

  defp order_number_of(order_uuid) do
    case PhoenixKitBilling.get_order(order_uuid, preload: []) do
      %Order{order_number: number} -> number
      nil -> nil
    end
  end

  defp order_number_of_shipment(shipment_uuid) do
    case Shipments.get_shipment(shipment_uuid) do
      %Shipment{order_uuid: order_uuid} -> order_number_of(order_uuid)
      nil -> nil
    end
  end

  defp order_number(%Shipment{order_uuid: order_uuid}), do: order_number_of(order_uuid)

  # -- the editor -------------------------------------------------------------

  @impl true
  def handle_info(
        {ShipmentDestinationEditor, :destination, _id, %Destination{} = destination},
        socket
      ) do
    case socket.assigns.editor do
      %{} = editor -> {:noreply, assign(socket, editor: %{editor | destination: destination})}
      nil -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp editor(kind, uuid, order, draft) do
    %{
      kind: kind,
      uuid: uuid,
      order_number: order.order_number,
      context: draft.context,
      service: draft.service,
      recipient: Map.new(@recipient_fields, &{&1, recipient_value(draft.recipient, &1)}),
      sent_recipient: Map.new(@recipient_fields, &{&1, recipient_value(draft.recipient, &1)}),
      parcels: Enum.map(non_empty(draft.parcels), &parcel_form/1),
      destination: draft.destination,
      error: nil
    }
  end

  # Only the fields the admin changed: the others are sent as the order (or
  # the last attempt) has them.
  defp recipient_correction(%{recipient: recipient, sent_recipient: sent}) do
    case Map.filter(recipient, fn {key, value} -> value != sent[key] end) do
      changed when changed == %{} -> nil
      changed -> changed
    end
  end

  # The phone as it was typed is what the admin corrects.
  defp recipient_value(recipient, "phone"),
    do: Codec.string(recipient["raw_phone"] || recipient["phone"]) || ""

  defp recipient_value(recipient, key), do: Codec.string(recipient[key]) || ""

  defp non_empty([]), do: [%Parcel{}]
  defp non_empty(parcels), do: parcels

  defp parcel_form(%Parcel{} = parcel) do
    for key <- [:weight_g, :length_mm, :width_mm, :height_mm], into: %{} do
      {Atom.to_string(key), parcel |> Map.get(key) |> to_text()}
    end
  end

  defp to_text(nil), do: ""
  defp to_text(value), do: to_string(value)

  @parcel_fields ~w(weight_g length_mm width_mm height_mm)

  # What the admin typed stays in the form, valid or not.
  defp take_form(editor, params) do
    %{
      editor
      | recipient: taken_recipient(editor.recipient, params["recipient"]),
        parcels: taken_parcels(editor.parcels, params["parcels"]),
        error: nil
    }
  end

  defp taken_recipient(recipient, %{} = given),
    do: Map.new(@recipient_fields, &{&1, text(given[&1]) || recipient[&1]})

  defp taken_recipient(recipient, _given), do: recipient

  # `parcels[<index>][<field>]`, in the order of the index.
  defp taken_parcels(parcels, %{} = given) do
    given
    |> Enum.flat_map(&indexed_parcel/1)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
    |> Enum.take(@max_parcels)
    |> case do
      [] -> parcels
      taken -> taken
    end
  end

  defp taken_parcels(parcels, _given), do: parcels

  defp indexed_parcel({index, %{} = fields}) do
    case Integer.parse(index) do
      {i, ""} -> [{i, Map.new(@parcel_fields, &{&1, text(fields[&1]) || ""})}]
      _ -> []
    end
  end

  defp indexed_parcel(_entry), do: []

  defp text(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, @field_length)

  defp text(_value), do: nil

  defp parse_parcels(forms) do
    forms
    |> Enum.reduce_while({:ok, []}, fn form, {:ok, acc} ->
      case parse_parcel(form) do
        {:ok, parcel} ->
          {:cont, {:ok, [parcel | acc]}}

        :error ->
          {:halt,
           {:error,
            gettext(
              "Enter each parcel's weight in grams, and its sizes in millimetres or nothing."
            )}}
      end
    end)
    |> case do
      {:ok, parcels} -> {:ok, Enum.reverse(parcels)}
      error -> error
    end
  end

  defp parse_parcel(form) do
    with {:ok, weight} when not is_nil(weight) <- number(form["weight_g"], 0),
         {:ok, length} <- number(form["length_mm"], 1),
         {:ok, width} <- number(form["width_mm"], 1),
         {:ok, height} <- number(form["height_mm"], 1) do
      {:ok, %Parcel{weight_g: weight, length_mm: length, width_mm: width, height_mm: height}}
    else
      _ -> :error
    end
  end

  defp number(value, min) do
    case String.trim(value || "") do
      "" ->
        {:ok, nil}

      text ->
        case Integer.parse(text) do
          {n, ""} when n >= min and n <= @max_dimension -> {:ok, n}
          _ -> :error
        end
    end
  end

  # -- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
      <.admin_page_header back={Routes.path("/admin/shop")}>
        <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">{gettext("Shipments")}</h1>
      </.admin_page_header>

      <.nav_tabs
        id="shipments-sections"
        active_tab={@section}
        class="mb-4"
        tabs={[
          %{
            id: "to_ship",
            label: gettext("To ship"),
            patch: url(assigns, section: "to_ship", status: nil),
            badge: badge(@counts.to_ship)
          },
          %{
            id: "open",
            label: gettext("Open"),
            patch: url(assigns, section: "open", status: nil),
            badge: badge(@counts.open)
          },
          %{
            id: "needs_attention",
            label: gettext("Needs attention"),
            patch: url(assigns, section: "needs_attention", status: nil),
            badge: badge(@counts.needs_attention),
            badge_class: "badge-warning"
          }
        ]}
      />

      <form id="shipments-filters" phx-change="filter" class="flex flex-wrap gap-4 mb-4">
        <div class="w-full sm:w-56">
          <.select
            id="shipments-filter-provider"
            name="provider"
            value={@provider}
            label={gettext("Carrier")}
            prompt={gettext("All carriers")}
            options={Enum.map(@providers, fn {key, label} -> {label, key} end)}
          />
        </div>
        <div :if={@section != "to_ship"} class="w-full sm:w-56">
          <.select
            id="shipments-filter-status"
            name="status"
            value={@status}
            label={gettext("Status")}
            prompt={gettext("All statuses")}
            options={Enum.map(section_statuses(@section), &{StatusLabels.shipment(&1), &1})}
          />
        </div>
      </form>

      <div :if={@running} id="shipments-running" class="alert alert-info mb-4" aria-live="polite">
        <span class="loading loading-spinner loading-sm"></span>
        <span>
          {running_text(@running)}
          <span :if={@batch} id="shipments-batch-progress">
            {gettext("(%{current} of %{total})", current: @batch.done + 1, total: @batch.total)}
          </span>
        </span>
      </div>

      <div :if={@outcomes != []} id="shipments-outcomes" class="card bg-base-100 shadow mb-4">
        <div class="card-body p-4">
          <div class="flex items-center justify-between">
            <h2 class="font-semibold">{gettext("Results")}</h2>
            <button id="shipments-outcomes-dismiss" type="button" class="btn btn-ghost btn-xs" phx-click="dismiss_outcomes">
              {gettext("Dismiss")}
            </button>
          </div>
          <ul class="space-y-1 text-sm">
            <li :for={outcome <- @outcomes} id={"shipments-outcome-#{outcome.id}"} class="flex gap-2">
              <span class={["badge badge-sm", tone_class(outcome.tone)]}>{outcome.number || "-"}</span>
              <span>{outcome.text}</span>
            </li>
          </ul>
        </div>
      </div>

      <fieldset disabled={not is_nil(@running)} class="min-w-0">
        <%= if @section == "to_ship" do %>
          <.to_ship_table streams={@streams} count={@counts.to_ship} selected={@selected_orders} />
        <% else %>
          <.shipments_table
            streams={@streams}
            section={@section}
            count={@section_count}
            selected={@selected_shipments}
            labels_check={@labels_check}
          />
        <% end %>
      </fieldset>

      <.modal :if={@editor_loading} show={true} on_close="close_editor" id="shipment-editor-pending">
        <div id="shipment-editor-loading" class="flex items-center gap-3 py-6" aria-live="polite">
          <span class="loading loading-spinner loading-md"></span>
          <span>{gettext("Loading the order's shipping details from the carrier...")}</span>
        </div>
      </.modal>
      <.editor_modal :if={@editor} editor={@editor} scope={@phoenix_kit_current_scope} />
      <.tracking_modal :if={@tracking} tracking={@tracking} />

      <.confirm_modal
        show={not is_nil(@confirm)}
        on_confirm="confirmed"
        on_cancel="close_confirm"
        title={confirm_title(@confirm)}
        messages={confirm_messages(@confirm)}
        danger={true}
      />
    </div>
    """
  end

  attr :streams, :map, required: true
  attr :count, :integer, required: true
  attr :selected, :list, required: true

  defp to_ship_table(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-2">
      <div>
        <p class="text-sm text-base-content/60">
          {ngettext("1 order to ship", "%{count} orders to ship", @count)}
        </p>
        <.truncated count={@count} />
      </div>
      <.button
        id="shipments-register-selected"
        size="sm"
        phx-click="register_selected"
        disabled={@selected == []}
      >
        {gettext("Register selected (%{count})", count: length(@selected))}
      </.button>
    </div>

    <form id="to-ship-selection" phx-change="select_orders">
      <.table_default id="to-ship-table" variant="zebra" class="w-full">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell class="w-8"></.table_default_header_cell>
            <.table_default_header_cell>{gettext("Order")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Recipient")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Destination")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Method")}</.table_default_header_cell>
            <.table_default_header_cell></.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body id="to-ship-rows" phx-update="stream">
          <tr id="to-ship-empty" class="hidden only:table-row">
            <td colspan="6" class="text-center py-10 text-base-content/50">
              {gettext("No paid order is waiting for a shipment.")}
            </td>
          </tr>
          <.table_default_row :for={{dom_id, {order, method}} <- @streams.orders} id={dom_id}>
            <.table_default_cell>
              <input
                id={"to-ship-select-#{order.uuid}"}
                type="checkbox"
                class="checkbox checkbox-sm"
                name="order_uuids[]"
                value={order.uuid}
              />
            </.table_default_cell>
            <.table_default_cell>
              <div class="font-medium">{order.order_number}</div>
              <div class="text-xs text-base-content/60">{format_datetime(order.paid_at || order.inserted_at)}</div>
            </.table_default_cell>
            <.table_default_cell>
              <div>{buyer_name(order)}</div>
              <div class="text-xs text-base-content/60">{(order.billing_snapshot || %{})["phone"]}</div>
            </.table_default_cell>
            <.table_default_cell class="max-w-xs break-words">
              {order_destination(order)}
            </.table_default_cell>
            <.table_default_cell>
              <div>{method.name}</div>
              <div class="text-xs text-base-content/60">{provider_label(method_provider(method))}</div>
            </.table_default_cell>
            <.table_default_cell class="text-right">
              <.button
                id={"to-ship-register-#{order.uuid}"}
                type="button"
                size="sm"
                variant="outline"
                phx-click="open_register"
                phx-value-uuid={order.uuid}
              >
                {gettext("Register")}
              </.button>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </form>
    """
  end

  attr :streams, :map, required: true
  attr :section, :string, required: true
  attr :count, :integer, required: true
  attr :selected, :list, required: true
  attr :labels_check, :any, required: true

  defp shipments_table(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-2">
      <div>
        <p class="text-sm text-base-content/60">
          {ngettext("1 shipment", "%{count} shipments", @count)}
        </p>
        <.truncated count={@count} />
      </div>
      <p :if={match?({:error, _}, @labels_check)} id="shipments-print-refused" class="text-sm text-error">
        {Errors.message(elem(@labels_check, 1))}
      </p>
      <.button
        :if={@selected != [] and @labels_check == :ok}
        id="shipments-print-selected"
        size="sm"
        href={labels_path(@selected)}
        target="_blank"
      >
        {gettext("Print labels (%{count})", count: length(@selected))}
      </.button>
    </div>

    <form id="shipments-selection" phx-change="select_shipments">
      <.table_default id="shipments-table" variant="zebra" class="w-full">
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell class="w-8"></.table_default_header_cell>
            <.table_default_header_cell>{gettext("Order")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Recipient")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Carrier")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Tracking number")}</.table_default_header_cell>
            <.table_default_header_cell></.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body id="shipments-rows" phx-update="stream">
          <tr id="shipments-empty" class="hidden only:table-row">
            <td colspan="7" class="text-center py-10 text-base-content/50">
              {if @section == "open",
                do: gettext("No shipment is on its way."),
                else: gettext("No shipment needs attention.")}
            </td>
          </tr>
          <.table_default_row :for={{dom_id, {shipment, order}} <- @streams.shipments} id={dom_id} class="align-top">
            <.table_default_cell>
              <input
                :if={labels?(shipment)}
                id={"shipment-select-#{shipment.uuid}"}
                type="checkbox"
                class="checkbox checkbox-sm"
                name="shipment_uuids[]"
                value={shipment.uuid}
              />
            </.table_default_cell>
            <.table_default_cell>
              <div class="font-medium">{order.order_number}</div>
              <div :if={Shipments.closed_order?(order)} id={"shipment-order-closed-#{shipment.uuid}"} class="badge badge-error badge-sm">
                {StatusLabels.order(order.status)}
              </div>
              <div class="text-xs text-base-content/60">{format_datetime(shipment.updated_at)}</div>
            </.table_default_cell>
            <.table_default_cell>
              <div>{(shipment.recipient || %{})["name"]}</div>
              <div class="text-xs text-base-content/60">{(shipment.recipient || %{})["phone"]}</div>
            </.table_default_cell>
            <.table_default_cell>
              <div>{shipment.carrier_label || provider_label(shipment.provider)}</div>
              <div class="text-xs text-base-content/60">{shipment.service}</div>
            </.table_default_cell>
            <.table_default_cell>
              <span id={"shipment-status-#{shipment.uuid}"} class={["badge badge-sm", shipment_badge_class(shipment)]}>
                {StatusLabels.shipment(shipment.status)}
              </span>
              <div :if={Shipments.stuck?(shipment)} class="text-xs text-warning mt-1">
                {gettext("No answer for 10 minutes")}
              </div>
              <.tracking_failing shipment={shipment} />
              <p :if={shipment.error} id={"shipment-error-#{shipment.uuid}"} class="text-xs text-error mt-1 max-w-xs break-words">
                {shipment.error}
              </p>
              <details :if={shipment.events != []} id={"shipment-events-#{shipment.uuid}"} class="text-xs mt-1">
                <summary class="cursor-pointer text-base-content/60">{gettext("History")}</summary>
                <ul class="mt-1 space-y-0.5">
                  <li :for={event <- Enum.reverse(shipment.events)}>
                    <span class="text-base-content/60">{event_time(event["at"])}</span>
                    {event_action(event["action"])}: {StatusLabels.shipment(event["status"])}
                    <span :if={event["message"]} class="block text-base-content/60 break-words">{event["message"]}</span>
                  </li>
                </ul>
              </details>
            </.table_default_cell>
            <.table_default_cell>
              <.tracking_number shipment={shipment} />
            </.table_default_cell>
            <.table_default_cell class="text-right">
              <div class="flex flex-wrap justify-end gap-1">
                <.button
                  :if={labels?(shipment)}
                  id={"shipment-label-#{shipment.uuid}"}
                  size="xs"
                  variant="ghost"
                  href={labels_path([shipment.uuid])}
                  target="_blank"
                >
                  {gettext("Print label")}
                </.button>
                <.button
                  :if={shipment.status == "failed" and not Shipments.closed_order?(order)}
                  id={"shipment-retry-#{shipment.uuid}"}
                  type="button"
                  size="xs"
                  phx-click="open_retry"
                  phx-value-uuid={shipment.uuid}
                >
                  {gettext("Retry")}
                </.button>
                <.button
                  :if={shipment.status == "failed" and Shipments.closed_order?(order)}
                  id={"shipment-close-#{shipment.uuid}"}
                  type="button"
                  size="xs"
                  variant="outline"
                  phx-click="close"
                  phx-value-uuid={shipment.uuid}
                >
                  {pgettext("shipment", "Close")}
                </.button>
                <.button
                  :if={resolvable?(shipment)}
                  id={"shipment-enter-tracking-#{shipment.uuid}"}
                  type="button"
                  size="xs"
                  variant="outline"
                  phx-click="open_tracking"
                  phx-value-uuid={shipment.uuid}
                >
                  {gettext("Enter tracking number")}
                </.button>
                <.button
                  :if={resolvable?(shipment)}
                  id={"shipment-mark-failed-#{shipment.uuid}"}
                  type="button"
                  size="xs"
                  variant="outline"
                  phx-click="mark_failed"
                  phx-value-uuid={shipment.uuid}
                >
                  {gettext("Mark failed")}
                </.button>
                <.button
                  :if={cancellable?(shipment)}
                  id={"shipment-cancel-#{shipment.uuid}"}
                  type="button"
                  size="xs"
                  variant="error"
                  phx-click="confirm"
                  phx-value-action="cancel"
                  phx-value-uuid={shipment.uuid}
                >
                  {gettext("Cancel")}
                </.button>
                <.button
                  :if={locally_cancellable?(shipment)}
                  id={"shipment-cancelled-at-carrier-#{shipment.uuid}"}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="confirm"
                  phx-value-action="cancelled_at_carrier"
                  phx-value-uuid={shipment.uuid}
                >
                  {gettext("Cancelled at the carrier")}
                </.button>
              </div>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
    </form>
    """
  end

  attr :shipment, :map, required: true

  # The carrier's tracking has been failing for the shipment.
  defp tracking_failing(assigns) do
    assigns = assign(assigns, :since, Shipments.tracking_failing_since(assigns.shipment))

    ~H"""
    <div
      :if={@since}
      id={"shipment-tracking-failing-#{@shipment.uuid}"}
      class="text-xs text-warning mt-1"
    >
      {gettext("Tracking failing since %{time}", time: format_datetime(@since))}
    </div>
    """
  end

  attr :shipment, :map, required: true

  # The number, as a link only when the stored link is a web address.
  defp tracking_number(assigns) do
    assigns = assign(assigns, :url, Shipments.web_url(assigns.shipment.tracking_url))

    ~H"""
    <%= cond do %>
      <% @url && @shipment.tracking_number -> %>
        <a href={@url} target="_blank" rel="noopener noreferrer" class="link font-mono text-sm">
          {@shipment.tracking_number}
        </a>
      <% @shipment.tracking_number -> %>
        <span class="font-mono text-sm">{@shipment.tracking_number}</span>
      <% true -> %>
        <span class="text-base-content/40">-</span>
    <% end %>
    """
  end

  attr :count, :integer, required: true

  # The lists stop at `Shipments.list_limit/0` rows; the count is of them all.
  defp truncated(assigns) do
    assigns = assign(assigns, :limit, Shipments.list_limit())

    ~H"""
    <p :if={@count > @limit} id="shipments-truncated" class="text-xs text-warning">
      {gettext("Showing the first %{limit} of %{count}. Narrow the list with the filters.",
        limit: @limit,
        count: @count
      )}
    </p>
    """
  end

  attr :editor, :map, required: true
  attr :scope, :any, required: true

  defp editor_modal(assigns) do
    ~H"""
    <.modal show={true} on_close="close_editor" max_width="2xl" id="shipment-editor">
      <:title>
        {if @editor.kind == :retry,
          do: gettext("Retry the shipment of order %{number}", number: @editor.order_number),
          else: gettext("Register the shipment of order %{number}", number: @editor.order_number)}
      </:title>

      <.form for={%{}} id="shipment-editor-form" phx-change="editor_change" phx-submit="submit_editor" class="space-y-4">
        <div>
          <h3 class="font-semibold mb-2">{gettext("Recipient")}</h3>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
            <.input id="shipment-editor-name" name="recipient[name]" value={@editor.recipient["name"]} label={gettext("Name")} />
            <.input id="shipment-editor-company" name="recipient[company]" value={@editor.recipient["company"]} label={gettext("Company")} />
            <.input id="shipment-editor-email" name="recipient[email]" value={@editor.recipient["email"]} label={gettext("Email")} />
            <.input id="shipment-editor-phone" name="recipient[phone]" value={@editor.recipient["phone"]} label={gettext("Phone")} />
          </div>
        </div>

        <div>
          <div class="flex items-center justify-between mb-2">
            <h3 class="font-semibold">{gettext("Parcels")}</h3>
            <button id="shipment-editor-add-parcel" type="button" class="btn btn-ghost btn-xs" phx-click="add_parcel">
              <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("Add a parcel")}
            </button>
          </div>
          <div :for={{parcel, index} <- Enum.with_index(@editor.parcels)} id={"shipment-editor-parcel-#{index}"} class="grid grid-cols-2 sm:grid-cols-5 gap-2 items-end mb-2">
            <.input id={"shipment-editor-parcel-#{index}-weight"} name={"parcels[#{index}][weight_g]"} value={parcel["weight_g"]} label={gettext("Weight (g)")} inputmode="numeric" />
            <.input id={"shipment-editor-parcel-#{index}-length"} name={"parcels[#{index}][length_mm]"} value={parcel["length_mm"]} label={gettext("Length (mm)")} inputmode="numeric" />
            <.input id={"shipment-editor-parcel-#{index}-width"} name={"parcels[#{index}][width_mm]"} value={parcel["width_mm"]} label={gettext("Width (mm)")} inputmode="numeric" />
            <.input id={"shipment-editor-parcel-#{index}-height"} name={"parcels[#{index}][height_mm]"} value={parcel["height_mm"]} label={gettext("Height (mm)")} inputmode="numeric" />
            <button
              :if={length(@editor.parcels) > 1}
              id={"shipment-editor-parcel-#{index}-remove"}
              type="button"
              class="btn btn-ghost btn-xs mb-2"
              phx-click="remove_parcel"
              phx-value-index={index}
            >
              {gettext("Remove")}
            </button>
          </div>
        </div>
      </.form>

      <div class="mt-4">
        <h3 class="font-semibold mb-2">{gettext("Destination")}</h3>
        <.live_component
          module={ShipmentDestinationEditor}
          id="shipment-editor-destination"
          context={@editor.context}
          service={@editor.service}
          destination={@editor.destination}
          phoenix_kit_current_scope={@scope}
        />
      </div>

      <p :if={@editor.error} id="shipment-editor-error" class="text-error text-sm mt-3">{@editor.error}</p>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_editor">{gettext("Cancel")}</button>
        <.button id="shipment-editor-submit" type="submit" form="shipment-editor-form">
          {if @editor.kind == :retry, do: gettext("Retry"), else: gettext("Register")}
        </.button>
      </:actions>
    </.modal>
    """
  end

  attr :tracking, :map, required: true

  defp tracking_modal(assigns) do
    ~H"""
    <.modal show={true} on_close="close_tracking" id="shipment-tracking">
      <:title>{gettext("Enter the tracking number")}</:title>
      <p class="text-sm text-base-content/70 mb-3">
        {gettext("Enter the number the carrier's portal shows for this shipment. The shipment is then registered.")}
      </p>
      <.form for={%{}} as={:tracking} id="shipment-tracking-form" phx-submit="submit_tracking" class="space-y-2">
        <.input id="shipment-tracking-number" name="tracking[tracking_number]" value={@tracking.tracking_number} label={gettext("Tracking number")} />
        <.input id="shipment-tracking-url" name="tracking[tracking_url]" value={@tracking.tracking_url} label={gettext("Tracking link (optional)")} />
        <p :if={@tracking.error} id="shipment-tracking-error" class="text-error text-sm">{@tracking.error}</p>
        <div class="flex justify-end gap-2 pt-2">
          <button type="button" class="btn btn-ghost" phx-click="close_tracking">{gettext("Cancel")}</button>
          <.button id="shipment-tracking-submit" type="submit">{gettext("Save")}</.button>
        </div>
      </.form>
    </.modal>
    """
  end

  # -- helpers --------------------------------------------------------------------

  defp section_statuses("open"), do: Shipments.section_statuses(:open)
  defp section_statuses("needs_attention"), do: Shipments.section_statuses(:needs_attention)
  defp section_statuses(_to_ship), do: []

  defp section_count(counts, "to_ship"), do: counts.to_ship
  defp section_count(counts, "open"), do: counts.open
  defp section_count(counts, "needs_attention"), do: counts.needs_attention

  defp tracking_url_text(value) when is_binary(value), do: String.trim(value)
  defp tracking_url_text(_value), do: ""

  defp badge(0), do: nil
  defp badge(count), do: count

  defp running_text(%{kind: :register, number: number}),
    do: gettext("Registering the shipment of order %{number} with the carrier...", number: number)

  defp running_text(%{kind: :retry, number: number}),
    do: gettext("Retrying the shipment of order %{number} with the carrier...", number: number)

  defp running_text(%{kind: :cancel, number: number}),
    do: gettext("Cancelling the shipment of order %{number} at the carrier...", number: number)

  defp confirm_title(%{action: "cancel"}), do: gettext("Cancel the shipment at the carrier?")
  defp confirm_title(%{action: "cancelled_at_carrier"}), do: gettext("Cancelled at the carrier?")
  defp confirm_title(_confirm), do: gettext("Confirm")

  defp confirm_messages(%{action: "cancel"}),
    do: [
      {:warning, gettext("The carrier is asked to cancel the shipment. This cannot be undone.")}
    ]

  defp confirm_messages(%{action: "cancelled_at_carrier"}),
    do: [
      {:warning,
       gettext(
         "Record the shipment as cancelled because it was cancelled in the carrier's portal. The carrier is not contacted."
       )}
    ]

  defp confirm_messages(_confirm), do: []

  defp tone_class(:success), do: "badge-success"
  defp tone_class(:warning), do: "badge-warning"
  defp tone_class(:error), do: "badge-error"

  defp shipment_badge_class(%Shipment{status: status}) when status in ["failed", "unknown"],
    do: "badge-error"

  defp shipment_badge_class(%Shipment{status: "creating"}), do: "badge-warning"
  defp shipment_badge_class(%Shipment{status: "delivered"}), do: "badge-success"

  defp shipment_badge_class(%Shipment{status: status})
       when status in ["created", "in_transit", "ready_for_pickup"],
       do: "badge-info"

  defp shipment_badge_class(_shipment), do: "badge-ghost"

  defp resolvable?(%Shipment{status: "unknown"}), do: true
  defp resolvable?(shipment), do: Shipments.stuck?(shipment)

  defp cancellable?(%Shipment{} = shipment),
    do: Shipments.printable?(shipment) and supports?(shipment.provider, :cancel_shipment)

  defp locally_cancellable?(%Shipment{status: status} = shipment),
    do:
      status in ["unknown", "created", "in_transit", "ready_for_pickup"] or
        Shipments.stuck?(shipment)

  defp labels?(%Shipment{} = shipment),
    do: Shipments.printable?(shipment) and supports?(shipment.provider, :print_labels)

  defp supports?(provider_key, operation) do
    case Shipping.provider(provider_key) do
      {:ok, provider} -> Shipping.supports?(provider, operation)
      :error -> false
    end
  end

  defp provider_label(key) do
    case Shipping.provider(key) do
      {:ok, provider} -> provider.label()
      :error -> key
    end
  end

  defp method_provider(method), do: Shipping.MethodConfig.from_method(method).provider

  defp buyer_name(%Order{billing_snapshot: snapshot}) when is_map(snapshot) do
    [snapshot["first_name"], snapshot["last_name"]]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join(" ")
    |> case do
      "" -> snapshot["company_name"]
      name -> name
    end
  end

  defp buyer_name(_order), do: nil

  defp order_destination(%Order{metadata: metadata}) do
    metadata
    |> Codec.get(:shipping_destination)
    |> Destination.from_map()
    |> CartQuote.destination_label()
  end

  defp event_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> format_datetime(datetime)
      _ -> at
    end
  end

  defp event_time(_at), do: "-"

  # The actions `Shipments` records on a shipment's events.
  defp event_action("register"), do: gettext("Registration started")
  defp event_action("submit"), do: gettext("Sent to the carrier")
  defp event_action("result"), do: gettext("Carrier's answer")
  defp event_action("retry"), do: gettext("Retried")
  defp event_action("mark_failed"), do: gettext("Marked failed")
  defp event_action("tracking_entered"), do: gettext("Tracking number entered")
  defp event_action("cancelled"), do: gettext("Cancelled at the carrier by the shop")
  defp event_action("cancelled_at_carrier"), do: gettext("Recorded as cancelled at the carrier")
  defp event_action("closed"), do: gettext("Closed, the order was cancelled or refunded")
  defp event_action("swept"), do: gettext("No answer for 10 minutes")
  defp event_action("tracked"), do: gettext("Carrier's tracking")
  defp event_action("tracking_failed"), do: gettext("Tracking failed")
  defp event_action("tracking_resumed"), do: gettext("Tracking answers again")
  defp event_action(action), do: to_string(action)

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
end
