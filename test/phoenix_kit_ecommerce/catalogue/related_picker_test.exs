defmodule PhoenixKitEcommerce.Catalogue.RelatedPickerTest do
  @moduledoc """
  The related-products pickers of the catalogue item form
  (`Catalogue.RelatedPicker`), hosted in a minimal LiveView the way the
  catalogue's own item form hosts them: pick, order, remove, and the hidden
  inputs the form submits.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Catalogue.ShopSections
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      {:ok, assign(socket, item: session["item"], ecommerce: session["ecommerce"])}
    end

    def render(assigns) do
      ~H"""
      <form id="host-form">
        <ShopSections.item item={@item} data={%{"ecommerce" => @ecommerce}} current_language="en" />
      </form>
      """
    end
  end

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    %{catalogue: catalogue}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end
  end

  defp item!(catalogue, name) do
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: name,
        base_price: Decimal.new("5.00"),
        status: "active"
      })

    item
  end

  defp host(conn, item, ecommerce \\ %{}) do
    live_isolated(conn, Host, session: %{"item" => item, "ecommerce" => ecommerce})
  end

  # The events are the component's: sent through the hook element of its search
  # box (inside the component), they reach it, whatever their name.
  defp hook(view, event, params),
    do: render_hook(element(view, "#ext-ecommerce-related-search"), event, params)

  defp inputs(view, kind) do
    name = Regex.escape("item[ecommerce][#{kind}][]")

    ~r/<input[^>]*name="#{name}"[^>]*value="([^"]*)"/
    |> Regex.scan(render(view))
    |> Enum.map(fn [_, value] -> value end)
  end

  test "the pickers mount inside the Shop section under its real ids, with no duplicate DOM id",
       %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Main")
    {:ok, view, _html} = host(conn, main)

    assert has_element?(view, "#ext-ecommerce-section")
    assert has_element?(view, "#ext-ecommerce-related")
    assert has_element?(view, "#ext-ecommerce-related-card")
    assert has_element?(view, "#ext-ecommerce-cross_sell-card")
  end

  test "an empty picker still submits the empty sentinel", %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Main")
    {:ok, view, _html} = host(conn, main)

    assert inputs(view, "related_product_uuids") == [""]
    assert inputs(view, "cross_sell_product_uuids") == [""]
  end

  test "stored lists are shown and submitted in order", %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Main")
    a = item!(catalogue, "Item A")
    b = item!(catalogue, "Item B")

    {:ok, view, html} =
      host(conn, main, %{"related_product_uuids" => [b.uuid, a.uuid]})

    assert html =~ "Item A"
    assert inputs(view, "related_product_uuids") == ["", b.uuid, a.uuid]
  end

  test "searching offers items other than the item itself and the chosen ones", %{
    conn: conn,
    catalogue: catalogue
  } do
    main = item!(catalogue, "Zeta main")
    chosen = item!(catalogue, "Zeta chosen")
    other = item!(catalogue, "Zeta other")

    {:ok, view, _html} = host(conn, main, %{"related_product_uuids" => [chosen.uuid]})
    hook(view, "related_search", %{"q" => "Zeta"})

    assert_push_event(view, "related_results", %{results: rows})
    assert Enum.map(rows, & &1.uuid) == [other.uuid]
  end

  test "pick, move and remove change what the form submits", %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Main")
    [a, b, c] = for t <- ~w(A B C), do: item!(catalogue, "Pick #{t}")

    {:ok, view, _html} = host(conn, main)

    for item <- [a, b, c], do: hook(view, "related_pick", %{"uuid" => item.uuid})
    hook(view, "cross_sell_pick", %{"uuid" => a.uuid})
    hook(view, "move_related", %{"uuid" => c.uuid, "direction" => "up", "kind" => "related"})
    hook(view, "remove_related", %{"uuid" => a.uuid, "kind" => "related"})

    assert inputs(view, "related_product_uuids") == ["", c.uuid, b.uuid]
    assert inputs(view, "cross_sell_product_uuids") == ["", a.uuid]
  end

  test "hostile payloads and the item itself are ignored", %{conn: conn, catalogue: catalogue} do
    main = item!(catalogue, "Main")
    {:ok, view, _html} = host(conn, main)

    hook(view, "related_pick", %{"uuid" => main.uuid})
    hook(view, "related_pick", %{"uuid" => 5})
    hook(view, "related_pick", %{"uuid" => "nope"})
    hook(view, "related_pick", %{"uuid" => Ecto.UUID.generate()})
    hook(view, "related_search", %{"q" => 7})
    hook(view, "remove_related", %{})
    hook(view, "move_related", %{"uuid" => 1, "direction" => "sideways"})

    assert inputs(view, "related_product_uuids") == [""]
  end
end
