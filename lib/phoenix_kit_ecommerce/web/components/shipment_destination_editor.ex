defmodule PhoenixKitEcommerce.Web.Components.ShipmentDestinationEditor do
  @moduledoc """
  The admin's editor of a shipment's destination, on the Shipments page:
  over the provider's own lookups (`Shipping.search_localities/2`,
  `Shipping.list_pickup_points/4`) in the context of the order's method. The
  checkout picker (`ShippingDestinationPicker`) is not reused: it reads and
  writes a cart.

  ## Assigns

    * `id` - the DOM id; the ids inside are derived from it
    * `context` - the `Shipping.Context` of the order's method
    * `service` - the `Shipping.Service` of the order, or `nil` when the
      provider could not list its services (the destination is then shown,
      not edited)
    * `destination` - the `Shipping.Destination` to start from

  A destination the admin completes is sent to the parent LiveView as
  `{ShipmentDestinationEditor, :destination, id, destination}`; nothing is
  stored here. The point lists are not narrowed by the parcels: the admin
  sees every point of the city.
  """

  use PhoenixKitEcommerce.Web, :live_component

  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{Address, CartQuote, Destination, Locality, PickupPoint}

  @max_points 50
  @query_length 64
  @field_length 255

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    {:ok,
     if Map.has_key?(socket.assigns, :editing) do
       socket
     else
       reset(socket)
     end}
  end

  defp reset(socket) do
    destination = socket.assigns.destination || %Destination{}
    locality = if searched_locality?(socket.assigns.service), do: destination.locality

    socket
    |> assign(
      editing: false,
      locality: locality,
      locality_query: "",
      localities: [],
      localities_state: :idle,
      points: [],
      point_query: "",
      points_state: :idle,
      lookup_error: nil,
      form: form_from(destination),
      errors: %{}
    )
  end

  # A locality the provider found (it has an id) is searched; one typed in
  # by hand is a text field of the forms below.
  defp searched_locality?(%Shipping.Service{lookup: :search, destination: kind})
       when kind in [:pickup_point, :address],
       do: true

  defp searched_locality?(_service), do: false

  defp form_from(%Destination{} = destination) do
    address = destination.address || %Address{}

    %{
      "locality" => field(destination.locality, :name),
      "point" => field(destination.pickup_point, :id),
      "postcode" => field(address, :postcode),
      "street" => field(address, :street),
      "house" => field(address, :house),
      "apartment" => field(address, :apartment)
    }
  end

  defp field(nil, _key), do: ""
  defp field(struct, key), do: Map.get(struct, key) || ""

  # -- lookups ------------------------------------------------------------

  @impl true
  def handle_async(:localities, {:ok, {:ok, localities}}, socket) do
    {:noreply,
     assign(socket,
       localities: Enum.filter(localities, &filled?(&1.id)),
       localities_state: :done
     )}
  end

  def handle_async(:localities, _failed, socket),
    do: {:noreply, assign(socket, localities_state: :error, lookup_error: lookup_error())}

  def handle_async(:points, {:ok, {:ok, points}}, socket) do
    {:noreply,
     assign(socket,
       points: points |> Enum.filter(&filled?(&1.id)) |> Enum.take(@max_points),
       points_state: :done
     )}
  end

  def handle_async(:points, _failed, socket),
    do: {:noreply, assign(socket, points_state: :error, lookup_error: lookup_error())}

  defp lookup_error, do: gettext("The carrier did not answer. Please try again.")

  defp load_points(socket) do
    %{context: ctx, locality: locality, point_query: query} = socket.assigns

    socket
    |> assign(points_state: :loading, lookup_error: nil)
    |> start_async(:points, fn -> Shipping.list_pickup_points(ctx, locality, query) end)
  end

  # -- events -------------------------------------------------------------

  @impl true
  def handle_event("edit", _params, socket) do
    if editable?(socket.assigns.service),
      do: {:noreply, socket |> reset() |> assign(editing: true) |> maybe_load_points()},
      else: {:noreply, socket}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, reset(socket)}

  def handle_event("locality_search", params, socket) do
    text = query_param(params)
    socket = assign(socket, locality_query: text, lookup_error: nil)

    if String.length(String.trim(text)) < 2 do
      {:noreply, assign(socket, localities: [], localities_state: :idle)}
    else
      ctx = socket.assigns.context

      {:noreply,
       socket
       |> assign(localities_state: :loading)
       |> start_async(:localities, fn -> Shipping.search_localities(ctx, text) end)}
    end
  end

  def handle_event("pick_locality", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.localities, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      locality ->
        {:noreply,
         socket
         |> assign(locality: locality, localities: [], localities_state: :idle, point_query: "")
         |> put_postcode(locality)
         |> maybe_load_points()}
    end
  end

  def handle_event("change_locality", _params, socket) do
    {:noreply, assign(socket, locality: nil, points: [], points_state: :idle, locality_query: "")}
  end

  def handle_event("filter_points", params, socket) do
    {:noreply, socket |> assign(point_query: query_param(params)) |> maybe_load_points()}
  end

  def handle_event("pick_point", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.points, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      point ->
        {:noreply,
         done(socket, %Destination{locality: socket.assigns.locality, pickup_point: point})}
    end
  end

  def handle_event("apply_manual", %{"manual" => params}, socket) when is_map(params) do
    if serves?(socket, :pickup_point),
      do: apply_manual(socket, params),
      else: {:noreply, socket}
  end

  def handle_event("apply_address", %{"address" => params}, socket) when is_map(params) do
    if serves?(socket, :address),
      do: apply_address(socket, params),
      else: {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The forms store only what the service asks for, and only while editing.
  defp serves?(%{assigns: %{editing: true, service: %Shipping.Service{destination: kind}}}, kind),
    do: true

  defp serves?(_socket, _kind), do: false

  defp apply_manual(socket, params) do
    locality = text(params, "locality")
    code = text(params, "point")

    errors =
      %{}
      |> require_text(:locality, locality, gettext("Please enter the city"))
      |> require_text(:point, code, gettext("Please enter the point code"))

    if errors == %{} do
      {:noreply,
       done(socket, %Destination{
         locality: %Locality{name: locality, country: socket.assigns.context.country},
         pickup_point: PickupPoint.manual(code)
       })}
    else
      {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params), errors: errors)}
    end
  end

  defp apply_address(socket, params) do
    searched? = searched_locality?(socket.assigns.service)
    service = socket.assigns.service

    errors =
      %{}
      |> require_text(:street, text(params, "street"), gettext("Please enter the street"))
      |> require_text(:house, text(params, "house"), gettext("Please enter the house number"))
      |> require_if(
        not searched?,
        :locality,
        text(params, "locality"),
        gettext("Please enter the city")
      )
      |> require_if(
        service.postcode_required,
        :postcode,
        text(params, "postcode"),
        gettext("Please enter the postcode")
      )

    if errors == %{} do
      locality =
        if searched?,
          do: socket.assigns.locality,
          else: %Locality{name: text(params, "locality"), country: socket.assigns.context.country}

      {:noreply,
       done(socket, %Destination{
         locality: locality,
         address: %Address{
           postcode: blank_to_nil(text(params, "postcode")),
           street: text(params, "street"),
           house: text(params, "house"),
           apartment: blank_to_nil(text(params, "apartment"))
         }
       })}
    else
      {:noreply, assign(socket, form: Map.merge(socket.assigns.form, params), errors: errors)}
    end
  end

  defp maybe_load_points(%{assigns: %{locality: %Locality{}, service: service}} = socket) do
    if match?(%Shipping.Service{destination: :pickup_point, lookup: :search}, service),
      do: load_points(socket),
      else: socket
  end

  defp maybe_load_points(socket), do: socket

  defp done(socket, %Destination{} = destination) do
    send(self(), {__MODULE__, :destination, socket.assigns.id, destination})
    socket |> assign(destination: destination) |> reset()
  end

  defp put_postcode(socket, %Locality{postcode: postcode}) when is_binary(postcode) do
    if socket.assigns.form["postcode"] in [nil, ""],
      do: assign(socket, form: Map.put(socket.assigns.form, "postcode", postcode)),
      else: socket
  end

  defp put_postcode(socket, _locality), do: socket

  defp query_param(%{"q" => text}) when is_binary(text), do: String.slice(text, 0, @query_length)
  defp query_param(_params), do: ""

  defp text(params, key) do
    case params[key] do
      value when is_binary(value) -> value |> String.trim() |> String.slice(0, @field_length)
      _ -> ""
    end
  end

  defp require_text(errors, key, "", message), do: Map.put(errors, key, message)
  defp require_text(errors, _key, _value, _message), do: errors

  defp require_if(errors, true, key, value, message),
    do: require_text(errors, key, value, message)

  defp require_if(errors, false, _key, _value, _message), do: errors

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp filled?(value), do: is_binary(value) and value != ""

  # -- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :label, CartQuote.destination_label(assigns.destination))

    ~H"""
    <div id={@id} class="space-y-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-xs text-base-content/60">{gettext("Deliver to")}</div>
          <div id={"#{@id}-summary"} class="font-medium break-words">{@label || "-"}</div>
        </div>
        <button
          :if={not @editing and editable?(@service)}
          id={"#{@id}-change"}
          type="button"
          class="btn btn-ghost btn-xs shrink-0"
          phx-click="edit"
          phx-target={@myself}
        >
          <.icon name="hero-pencil" class="w-3.5 h-3.5" /> {gettext("Change")}
        </button>
      </div>

      <p :if={is_nil(@service)} id={"#{@id}-unavailable"} class="text-sm text-base-content/60">
        {gettext("The carrier's services could not be loaded, so the destination cannot be changed now.")}
      </p>

      <div :if={@editing} id={"#{@id}-editor"} class="space-y-3 rounded-box border border-base-300 p-3">
        <%= if searched_locality?(@service) do %>
          <%= if @locality do %>
            <div class="flex items-center justify-between gap-3">
              <div id={"#{@id}-locality-selected"} class="font-medium">{@locality.name}</div>
              <button
                id={"#{@id}-locality-change"}
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="change_locality"
                phx-target={@myself}
              >
                {gettext("Change city")}
              </button>
            </div>
          <% else %>
            <form
              id={"#{@id}-locality-form"}
              phx-change="locality_search"
              phx-submit="locality_search"
              phx-target={@myself}
            >
              <.input
                id={"#{@id}-locality-input"}
                name="q"
                value={@locality_query}
                label={gettext("City")}
                autocomplete="off"
                maxlength="64"
                phx-debounce="300"
              />
            </form>
            <p :if={@localities_state == :loading} class="text-sm text-base-content/60">
              {gettext("Searching...")}
            </p>
            <p :if={@localities_state == :done and @localities == []} class="text-sm text-base-content/60">
              {gettext("Nothing found. Check the spelling and try again.")}
            </p>
            <ul :if={@localities != []} class="menu menu-sm w-full rounded-box border border-base-300">
              <li :for={locality <- @localities}>
                <button
                  id={"#{@id}-locality-option-#{dom_id(locality.id)}"}
                  type="button"
                  phx-click="pick_locality"
                  phx-value-id={locality.id}
                  phx-target={@myself}
                >
                  <span class="font-medium">{locality.name}</span>
                  <span :if={locality.region} class="text-xs text-base-content/60">{locality.region}</span>
                </button>
              </li>
            </ul>
          <% end %>
        <% end %>

        <div :if={@service.destination == :pickup_point and @service.lookup == :search and @locality} class="space-y-2">
          <form
            id={"#{@id}-points-form"}
            phx-change="filter_points"
            phx-submit="filter_points"
            phx-target={@myself}
          >
            <.input
              id={"#{@id}-point-filter"}
              name="q"
              value={@point_query}
              label={gettext("Delivery point")}
              placeholder={gettext("Search by number, name or address")}
              autocomplete="off"
              maxlength="64"
              phx-debounce="300"
            />
          </form>
          <p :if={@points_state == :loading} class="text-sm text-base-content/60">
            {gettext("Loading the list...")}
          </p>
          <p :if={@points_state == :done and @points == []} class="text-sm text-base-content/60">
            {gettext("No delivery points found for this search.")}
          </p>
          <div :if={@points != []} class="max-h-60 overflow-y-auto rounded-box border border-base-300 divide-y divide-base-200">
            <button
              :for={point <- @points}
              id={"#{@id}-point-#{dom_id(point.id)}"}
              type="button"
              class="block w-full p-2 text-left text-sm hover:bg-base-200"
              phx-click="pick_point"
              phx-value-id={point.id}
              phx-target={@myself}
            >
              <span class="font-medium">{point.name || point.number || point.id}</span>
              <span :if={point.address} class="block text-xs text-base-content/60">{point.address}</span>
            </button>
          </div>
        </div>

        <form
          :if={@service.destination == :pickup_point and @service.lookup == :manual}
          id={"#{@id}-manual-form"}
          phx-submit="apply_manual"
          phx-target={@myself}
          class="space-y-2"
        >
          <.input id={"#{@id}-manual-locality"} name="manual[locality]" value={@form["locality"]} label={gettext("City")} errors={List.wrap(@errors[:locality])} />
          <.input
            id={"#{@id}-manual-point"}
            name="manual[point]"
            value={@form["point"]}
            label={@service.point_code_label || gettext("Point code")}
            errors={List.wrap(@errors[:point])}
          />
          <.button id={"#{@id}-manual-apply"} type="submit" size="sm">{gettext("Use this point")}</.button>
        </form>

        <form
          :if={@service.destination == :address and (not searched_locality?(@service) or @locality)}
          id={"#{@id}-address-form"}
          phx-submit="apply_address"
          phx-target={@myself}
          class="grid grid-cols-1 sm:grid-cols-2 gap-2"
        >
          <.input
            :if={not searched_locality?(@service)}
            id={"#{@id}-address-locality"}
            name="address[locality]"
            value={@form["locality"]}
            label={gettext("City")}
            errors={List.wrap(@errors[:locality])}
          />
          <.input id={"#{@id}-address-postcode"} name="address[postcode]" value={@form["postcode"]} label={gettext("Postcode")} errors={List.wrap(@errors[:postcode])} />
          <.input id={"#{@id}-address-street"} name="address[street]" value={@form["street"]} label={gettext("Street")} errors={List.wrap(@errors[:street])} />
          <.input id={"#{@id}-address-house"} name="address[house]" value={@form["house"]} label={gettext("House")} errors={List.wrap(@errors[:house])} />
          <.input id={"#{@id}-address-apartment"} name="address[apartment]" value={@form["apartment"]} label={gettext("Apartment")} />
          <div class="sm:col-span-2">
            <.button id={"#{@id}-address-apply"} type="submit" size="sm">{gettext("Use this address")}</.button>
          </div>
        </form>

        <p :if={@lookup_error} class="text-sm text-error">{@lookup_error}</p>

        <button
          id={"#{@id}-cancel"}
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="cancel"
          phx-target={@myself}
        >
          {gettext("Cancel")}
        </button>
      </div>
    </div>
    """
  end

  defp editable?(%Shipping.Service{destination: kind}) when kind in [:pickup_point, :address],
    do: true

  defp editable?(_service), do: false

  defp dom_id(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")
end
