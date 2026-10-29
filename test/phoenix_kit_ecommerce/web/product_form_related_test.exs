defmodule PhoenixKitEcommerce.Web.ProductFormRelatedTest do
  @moduledoc """
  The "Related products" card of the product form: pick, order, remove, save,
  and what a hostile payload or a stale list does.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.RelatedProducts

  setup %{conn: conn} do
    %{conn: put_test_scope(conn, fake_scope())}
  end

  defp product!(title, attrs \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{"title" => %{"en" => title}, "price" => Decimal.new("10.00"), "status" => "active"},
          attrs
        )
      )

    product
  end

  defp related(product), do: RelatedProducts.uuids(Shop.get_product!(product.uuid))

  defp edit(conn, product), do: live(conn, "/en/admin/shop/products/#{product.uuid}/edit")

  defp save(view), do: view |> form("#product-form", %{}) |> render_submit()

  test "the card is on the form, empty, with a picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/products/new")

    assert has_element?(view, "#product-related")
    assert has_element?(view, "#related-products-search")
    refute has_element?(view, "#related-products-list")
  end

  test "searching offers matches, never the product itself nor a chosen one", %{conn: conn} do
    main = product!("Calendar main")
    chosen = product!("Calendar chosen")
    other = product!("Calendar other")

    {:ok, _} =
      Shop.update_product(main, %{"metadata" => %{"related_product_uuids" => [chosen.uuid]}})

    {:ok, view, _html} = edit(conn, main)
    render_hook(view, "related_search", %{"q" => "Calendar", "id" => "related-products-search"})

    assert_push_event(view, "related_results", %{results: rows, q: "Calendar"})
    assert Enum.map(rows, & &1.uuid) == [other.uuid]
  end

  test "an empty search offers nothing", %{conn: conn} do
    main = product!("Solo")
    {:ok, view, _html} = edit(conn, main)

    render_hook(view, "related_search", %{"q" => "   "})
    assert_push_event(view, "related_results", %{results: []})
  end

  test "picked products are saved in the order picked and show as chips", %{conn: conn} do
    main = product!("Main")
    a = product!("Alpha")
    b = product!("Beta")

    {:ok, view, _html} = edit(conn, main)
    render_hook(view, "related_pick", %{"uuid" => b.uuid})
    render_hook(view, "related_pick", %{"uuid" => a.uuid})

    assert has_element?(view, "#related-product-#{a.uuid}")
    assert has_element?(view, "#related-product-#{b.uuid}")

    save(view)
    assert related(main) == [b.uuid, a.uuid]
  end

  test "an entry can be moved and removed", %{conn: conn} do
    main = product!("Main")
    [a, b, c] = for t <- ~w(A B C), do: product!("Item #{t}")

    {:ok, view, _html} = edit(conn, main)
    for p <- [a, b, c], do: render_hook(view, "related_pick", %{"uuid" => p.uuid})

    render_hook(view, "move_related", %{"uuid" => c.uuid, "direction" => "up"})
    render_hook(view, "move_related", %{"uuid" => a.uuid, "direction" => "up"})
    render_hook(view, "remove_related", %{"uuid" => b.uuid})
    save(view)

    assert related(main) == [a.uuid, c.uuid]
  end

  test "emptying the list removes the key, other metadata stays", %{conn: conn} do
    other = product!("Other")

    main =
      product!("Main", %{
        "metadata" => %{
          "related_product_uuids" => [other.uuid],
          "_translation_fingerprints" => %{"x" => "1"}
        }
      })

    {:ok, view, _html} = edit(conn, main)
    render_hook(view, "remove_related", %{"uuid" => other.uuid})
    save(view)

    stored = Shop.get_product!(main.uuid).metadata
    refute Map.has_key?(stored, "related_product_uuids")
    assert stored["_translation_fingerprints"] == %{"x" => "1"}
  end

  test "saving other fields keeps the list and other keys untouched", %{conn: conn} do
    other = product!("Other")

    main =
      product!("Main", %{
        "metadata" => %{"related_product_uuids" => [other.uuid], "_discovered" => %{"k" => "v"}}
      })

    {:ok, view, _html} = edit(conn, main)
    view |> form("#product-form", %{"product" => %{"vendor" => "Acme"}}) |> render_submit()

    stored = Shop.get_product!(main.uuid)
    assert stored.vendor == "Acme"
    assert related(main) == [other.uuid]
    assert stored.metadata["_discovered"] == %{"k" => "v"}
  end

  test "a deleted product drops out of the list on the next save", %{conn: conn} do
    gone = product!("Gone")
    kept = product!("Kept")

    main =
      product!("Main", %{"metadata" => %{"related_product_uuids" => [gone.uuid, kept.uuid]}})

    {:ok, _} = Shop.delete_product(gone)

    {:ok, view, _html} = edit(conn, main)
    refute has_element?(view, "#related-product-#{gone.uuid}")
    save(view)

    assert related(main) == [kept.uuid]
  end

  test "a hostile payload is ignored, not a crash", %{conn: conn} do
    main = product!("Main")
    {:ok, view, _html} = edit(conn, main)

    render_hook(view, "related_pick", %{"uuid" => 5})
    render_hook(view, "related_pick", %{"uuid" => "not-a-uuid"})
    render_hook(view, "related_pick", %{"uuid" => Ecto.UUID.generate()})
    render_hook(view, "related_pick", %{"uuid" => main.uuid})
    render_hook(view, "move_related", %{"uuid" => 1, "direction" => "sideways"})
    render_hook(view, "remove_related", %{})
    render_hook(view, "related_search", %{"q" => 7})

    save(view)
    assert related(main) == []
  end

  test "the list stops at the maximum", %{conn: conn} do
    main = product!("Main")
    products = for i <- 1..(RelatedProducts.max_items() + 2), do: product!("Bulk #{i}")

    {:ok, view, _html} = edit(conn, main)
    for p <- products, do: render_hook(view, "related_pick", %{"uuid" => p.uuid})
    save(view)

    assert length(related(main)) == RelatedProducts.max_items()
    refute has_element?(view, "#related-products-search")
  end

  test "cross-sells are a separate list with their own picker", %{conn: conn} do
    main = product!("Main")
    related = product!("Related one")
    extra = product!("Cart extra")

    {:ok, view, _html} = edit(conn, main)
    assert has_element?(view, "#product-cross-sell")
    assert has_element?(view, "#cross-sell-products-search")

    render_hook(view, "related_pick", %{"uuid" => related.uuid})
    render_hook(view, "cross_sell_pick", %{"uuid" => extra.uuid})

    assert has_element?(view, "#related-product-#{related.uuid}")
    refute has_element?(view, "#related-product-#{extra.uuid}")
    assert has_element?(view, "#cross-sell-product-#{extra.uuid}")

    save(view)
    stored = Shop.get_product!(main.uuid)
    assert RelatedProducts.uuids(stored, :related) == [related.uuid]
    assert RelatedProducts.uuids(stored, :cross_sell) == [extra.uuid]
  end

  test "a cross-sell can be moved and removed without touching the other list", %{conn: conn} do
    main = product!("Main")
    [a, b] = for t <- ~w(A B), do: product!("Cross #{t}")
    keep = product!("Kept related")

    {:ok, view, _html} = edit(conn, main)
    render_hook(view, "related_pick", %{"uuid" => keep.uuid})
    for p <- [a, b], do: render_hook(view, "cross_sell_pick", %{"uuid" => p.uuid})

    render_hook(view, "move_related", %{
      "uuid" => b.uuid,
      "direction" => "up",
      "kind" => "cross_sell"
    })

    render_hook(view, "remove_related", %{"uuid" => a.uuid, "kind" => "cross_sell"})
    save(view)

    stored = Shop.get_product!(main.uuid)
    assert RelatedProducts.uuids(stored, :cross_sell) == [b.uuid]
    assert RelatedProducts.uuids(stored, :related) == [keep.uuid]
  end

  test "searching offers products the other list already holds, not this list's own", %{
    conn: conn
  } do
    main = product!("Main")
    held = product!("Zebra held")
    {:ok, view, _html} = edit(conn, main)

    render_hook(view, "related_pick", %{"uuid" => held.uuid})
    render_hook(view, "cross_sell_search", %{"q" => "Zebra"})
    assert_push_event(view, "cross_sell_results", %{results: [%{uuid: uuid}]})
    assert uuid == held.uuid

    render_hook(view, "related_search", %{"q" => "Zebra"})
    assert_push_event(view, "related_results", %{results: []})
  end
end
