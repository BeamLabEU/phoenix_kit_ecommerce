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
    render_hook(view, "picker_search", %{"q" => "Calendar", "id" => "related-products-search"})

    assert_push_event(view, "picker_results", %{results: rows, q: "Calendar"})
    assert Enum.map(rows, & &1.uuid) == [other.uuid]
  end

  test "an empty search offers nothing", %{conn: conn} do
    main = product!("Solo")
    {:ok, view, _html} = edit(conn, main)

    render_hook(view, "picker_search", %{"q" => "   "})
    assert_push_event(view, "picker_results", %{results: []})
  end

  test "search can fill all twelve slots when the newest matches are already picked", %{
    conn: conn
  } do
    products = for i <- 1..14, do: product!("Shared title #{i}")
    main = product!("Shared title main")
    {:ok, view, _html} = edit(conn, main)
    picked = products |> Enum.reverse() |> Enum.take(10)

    for product <- picked, do: render_hook(view, "picker_pick", %{"uuid" => product.uuid})

    render_hook(view, "picker_search", %{"q" => "Shared title", "limit" => 8})
    assert_push_event(view, "picker_results", %{results: rows})
    assert length(rows) == 4

    for row <- Enum.take(rows, 2), do: render_hook(view, "picker_pick", %{"uuid" => row.uuid})
    save(view)

    assert length(related(main)) == RelatedProducts.max_items()
  end

  test "search supports the picker's load more requests", %{conn: conn} do
    products = for i <- 1..19, do: product!("Pageable #{i}")
    main = product!("Main")
    {:ok, view, _html} = edit(conn, main)

    render_hook(view, "picker_search", %{
      "id" => "related-products-search",
      "q" => "Pageable",
      "limit" => 8
    })

    assert_push_event(view, "picker_results", %{
      id: "related-products-search",
      results: first,
      has_more: true
    })

    assert length(first) == 8

    render_hook(view, "picker_search", %{"q" => "Pageable", "limit" => 16})
    assert_push_event(view, "picker_results", %{results: more, has_more: true})
    assert length(more) == 16
    assert Enum.take(more, 8) == first

    render_hook(view, "picker_search", %{"q" => "Pageable", "limit" => 24})
    assert_push_event(view, "picker_results", %{results: all, has_more: false})
    assert Enum.sort(Enum.map(all, & &1.uuid)) == Enum.sort(Enum.map(products, & &1.uuid))
  end

  test "malformed search limits keep the default page size", %{conn: conn} do
    for i <- 1..10, do: product!("Limit check #{i}")
    {:ok, view, _html} = edit(conn, product!("Main"))

    for limit <- [nil, 0, -1, "16", 1.5, %{}] do
      render_hook(view, "picker_search", %{"q" => "Limit check", "limit" => limit})
      assert_push_event(view, "picker_results", %{results: rows, has_more: true})
      assert length(rows) == 8
    end
  end

  test "revoked catalog access also stops removing and reordering staged products", %{conn: conn} do
    a = product!("Alpha")
    b = product!("Beta")
    main = product!("Main", %{"metadata" => %{"related_product_uuids" => [a.uuid, b.uuid]}})
    {:ok, view, _html} = edit(conn, main)
    swap_scope(view, fake_scope(permissions: ["shop"], roles: ["Employee"]))

    render_hook(view, "move_related", %{"uuid" => b.uuid, "direction" => "up"})
    render_hook(view, "remove_related", %{"uuid" => a.uuid})

    assert has_element?(view, "#related-products-list li:first-child#related-product-#{a.uuid}")
    assert has_element?(view, "#related-products-list li:last-child#related-product-#{b.uuid}")
    assert render(view) =~ "You don&#39;t have permission"
  end

  test "picked products are saved in the order picked and show as chips", %{conn: conn} do
    main = product!("Main")
    a = product!("Alpha")
    b = product!("Beta")

    {:ok, view, _html} = edit(conn, main)
    render_hook(view, "picker_pick", %{"uuid" => b.uuid})
    render_hook(view, "picker_pick", %{"uuid" => a.uuid})

    assert has_element?(view, "#related-product-#{a.uuid}")
    assert has_element?(view, "#related-product-#{b.uuid}")

    save(view)
    assert related(main) == [b.uuid, a.uuid]
  end

  test "an entry can be moved and removed", %{conn: conn} do
    main = product!("Main")
    [a, b, c] = for t <- ~w(A B C), do: product!("Item #{t}")

    {:ok, view, _html} = edit(conn, main)
    for p <- [a, b, c], do: render_hook(view, "picker_pick", %{"uuid" => p.uuid})

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

    render_hook(view, "picker_pick", %{"uuid" => 5})
    render_hook(view, "picker_pick", %{"uuid" => "not-a-uuid"})
    render_hook(view, "picker_pick", %{"uuid" => Ecto.UUID.generate()})
    render_hook(view, "picker_pick", %{"uuid" => main.uuid})
    render_hook(view, "move_related", %{"uuid" => 1, "direction" => "sideways"})
    render_hook(view, "remove_related", %{})
    render_hook(view, "picker_search", %{"q" => 7})

    save(view)
    assert related(main) == []
  end

  test "metadata submitted with the form never overwrites the list the picker holds", %{
    conn: conn
  } do
    kept = product!("Kept")
    other = product!("Other")
    main = product!("Main", %{"metadata" => %{"related_product_uuids" => [kept.uuid]}})

    {:ok, view, _html} = edit(conn, main)

    for hostile <- [[other.uuid], ["junk", 5, true], 7, "garbage", %{"x" => 1}] do
      render_hook(view, "save", %{
        "product" => %{
          "title" => "Main",
          "price" => "10.00",
          "metadata" => %{"related_product_uuids" => hostile}
        }
      })

      assert related(main) == [kept.uuid]
    end
  end

  test "the list stops at the maximum", %{conn: conn} do
    main = product!("Main")
    products = for i <- 1..(RelatedProducts.max_items() + 2), do: product!("Bulk #{i}")

    {:ok, view, _html} = edit(conn, main)
    for p <- products, do: render_hook(view, "picker_pick", %{"uuid" => p.uuid})
    save(view)

    assert length(related(main)) == RelatedProducts.max_items()
    refute has_element?(view, "#related-products-search")
  end
end
