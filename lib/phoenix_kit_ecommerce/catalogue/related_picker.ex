defmodule PhoenixKitEcommerce.Catalogue.RelatedPicker do
  @moduledoc """
  The two hand-picked product lists of a catalogue item ("You may also like"
  on its page, "Add to your order" in the cart) inside the Shop section of the
  catalogue item form.

  `ShopSections.item/1` is a function component of the catalogue's own
  LiveView, which knows nothing of these lists, so the pickers are a
  LiveComponent: it handles its own search, pick, move and remove events and
  renders the result as hidden `item[ecommerce][...][]` inputs the form
  submits. An always-present empty input stands for an emptied list (the form
  would otherwise send nothing and the stored list could never be cleared);
  `ItemCommerce.cast/2` drops it.

  The component keeps its lists in its own assigns after the first render:
  the form re-renders on every keystroke and must not reset a pick.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]

  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.RelatedProducts

  @kinds [:related, :cross_sell]

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:item_uuid, item_uuid(assigns[:item]))

    if socket.assigns[:ready?] do
      {:ok, socket}
    else
      ecommerce = Map.get(assigns, :ecommerce) || %{}

      lists =
        Map.new(@kinds, fn kind ->
          key = RelatedProducts.metadata_key(kind)
          {kind, RelatedProducts.normalize(Map.get(ecommerce, key), socket.assigns.item_uuid)}
        end)

      {:ok,
       socket
       |> assign(:ready?, true)
       |> assign(:lists, lists)
       |> assign(:titles, %{})
       |> load_titles()}
    end
  end

  defp item_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp item_uuid(_item), do: nil

  # Titles of the chosen items; an item that no longer exists drops out.
  defp load_titles(socket) do
    uuids = socket.assigns.lists |> Map.values() |> List.flatten() |> Enum.uniq()
    found = uuids |> Query.list_items_by_uuids() |> Map.new(&{&1.uuid, &1.name})

    lists =
      Map.new(socket.assigns.lists, fn {kind, ids} ->
        {kind, Enum.filter(ids, &Map.has_key?(found, &1))}
      end)

    assign(socket, lists: lists, titles: Map.merge(socket.assigns.titles, found))
  end

  @impl true
  def handle_event(event, %{"q" => query} = params, socket)
      when event in ~w(related_search cross_sell_search) and is_binary(query) do
    kind = kind(event)
    limit = search_limit(params["limit"])
    rows = search_rows(socket, kind, String.trim(query), limit + 1)

    {:noreply,
     push_event(socket, "#{kind}_results", %{
       q: query,
       id: params["id"],
       results: Enum.take(rows, limit),
       has_more: length(rows) > limit and limit < 100
     })}
  end

  def handle_event(event, %{"uuid" => uuid}, socket)
      when event in ~w(related_pick cross_sell_pick) and is_binary(uuid) do
    kind = kind(event)
    current = socket.assigns.lists[kind]

    socket =
      case RelatedProducts.normalize(current ++ [uuid], socket.assigns.item_uuid) do
        ^current -> socket
        updated -> socket |> put_list(kind, updated) |> load_titles()
      end

    {:noreply, push_event(socket, "#{kind}_staged", %{})}
  end

  def handle_event("remove_related", %{"uuid" => uuid} = params, socket) when is_binary(uuid) do
    kind = kind(params["kind"])
    {:noreply, put_list(socket, kind, List.delete(socket.assigns.lists[kind], uuid))}
  end

  def handle_event("move_related", %{"uuid" => uuid, "direction" => direction} = params, socket)
      when direction in ~w(up down) do
    kind = kind(params["kind"])
    {:noreply, put_list(socket, kind, move(socket.assigns.lists[kind], uuid, direction))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp kind("cross_sell" <> _), do: :cross_sell
  defp kind(_other), do: :related

  defp put_list(socket, kind, uuids),
    do: assign(socket, :lists, Map.put(socket.assigns.lists, kind, uuids))

  defp move(uuids, uuid, direction) do
    case Enum.find_index(uuids, &(&1 == uuid)) do
      nil ->
        uuids

      index ->
        target = if direction == "up", do: index - 1, else: index + 1

        if target in 0..(length(uuids) - 1)//1 do
          uuids |> List.delete_at(index) |> List.insert_at(target, uuid)
        else
          uuids
        end
    end
  end

  defp search_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 100)
  defp search_limit(_limit), do: 8

  defp search_rows(_socket, _kind, "", _limit), do: []

  # The ones already chosen (and the item itself) are left out in the query,
  # before the limit, so they cannot crowd out the matches that remain.
  defp search_rows(socket, kind, query, limit) do
    taken = Enum.reject([socket.assigns.item_uuid | socket.assigns.lists[kind]], &is_nil/1)

    [search: query, per_page: limit, page: 1, exclude_uuids: taken]
    |> Query.list_items()
    |> Enum.map(fn item ->
      %{
        kind: "product",
        uuid: item.uuid,
        label: item.name,
        sublabel: item.status,
        icon: "hero-cube"
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="mt-6 space-y-6">
      <.list_card
        :for={{kind, title, hint} <- cards()}
        kind={kind}
        title={title}
        hint={hint}
        uuids={@lists[kind]}
        titles={@titles}
        target={@myself}
      />
    </div>
    """
  end

  defp cards do
    [
      {:related, gettext("Related products"),
       gettext(
         "Shown under this product as \"You may also like\", in this order. Drafts and hidden products are never shown to shoppers."
       )},
      {:cross_sell, gettext("Cross-sells"),
       gettext(
         "Offered in the cart when this product is in it (\"Add to your order\"), in this order. Drafts and hidden products are never shown to shoppers."
       )}
    ]
  end

  attr :kind, :atom, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true
  attr :uuids, :list, required: true
  attr :titles, :map, required: true
  attr :target, :any, required: true

  defp list_card(assigns) do
    assigns =
      assign(assigns, :name, "item[ecommerce][#{RelatedProducts.metadata_key(assigns.kind)}][]")

    ~H"""
    <div id={"ext-ecommerce-#{@kind}-card"}>
      <h3 class="text-sm font-semibold text-base-content/80 mb-1">{@title}</h3>
      <p class="text-xs text-base-content/60 mb-3">{@hint}</p>

      <input type="hidden" name={@name} value="" />
      <input :for={uuid <- @uuids} type="hidden" name={@name} value={uuid} />

      <ul :if={@uuids != []} class="space-y-2 mb-3">
        <li
          :for={{uuid, index} <- Enum.with_index(@uuids)}
          id={"ext-ecommerce-#{@kind}-#{uuid}"}
          class="flex items-center gap-2 rounded-lg bg-base-200 px-3 py-2"
        >
          <span class="flex-1 truncate">{@titles[uuid]}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="move_related"
            phx-target={@target}
            phx-value-uuid={uuid}
            phx-value-kind={@kind}
            phx-value-direction="up"
            disabled={index == 0}
            aria-label={gettext("Move up")}
          >
            <.icon name="hero-arrow-up" class="w-4 h-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="move_related"
            phx-target={@target}
            phx-value-uuid={uuid}
            phx-value-kind={@kind}
            phx-value-direction="down"
            disabled={index == length(@uuids) - 1}
            aria-label={gettext("Move down")}
          >
            <.icon name="hero-arrow-down" class="w-4 h-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="remove_related"
            phx-target={@target}
            phx-value-uuid={uuid}
            phx-value-kind={@kind}
            aria-label={gettext("Remove")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </li>
      </ul>

      <%= if length(@uuids) < RelatedProducts.max_items() do %>
        <.search_picker
          id={"ext-ecommerce-#{@kind}-search"}
          dropdown_id={"ext-ecommerce-#{@kind}-dropdown"}
          search_event={"#{@kind}_search"}
          results_event={"#{@kind}_results"}
          pick_event={"#{@kind}_pick"}
          staged_event={"#{@kind}_staged"}
          phx-target={@target}
          placeholder={gettext("Search products to add...")}
          searching_label={gettext("Searching...")}
          no_matches_label={gettext("No matches")}
        />
      <% else %>
        <p class="text-sm text-base-content/60">
          {gettext("The list is full (%{max} products).", max: RelatedProducts.max_items())}
        </p>
      <% end %>
    </div>
    """
  end
end
