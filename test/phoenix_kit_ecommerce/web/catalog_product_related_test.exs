defmodule PhoenixKitEcommerce.Web.CatalogProductRelatedTest do
  @moduledoc """
  The "You may also like" block of the product page: what it shows, what it
  hides, and that a page without a list is exactly what it was.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.RelatedProducts

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp product!(title, attrs \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => title, lang() => title},
            "slug" => %{lang() => "rel-#{System.unique_integer([:positive])}"},
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "currency" => "USD",
            "requires_shipping" => false
          },
          attrs
        )
      )

    product
  end

  defp with_related(product, ids) do
    {:ok, product} =
      Shop.update_product(product, %{"metadata" => %{RelatedProducts.metadata_key() => ids}})

    product
  end

  defp page(conn, product), do: live(conn, "/shop/product/#{product.slug[lang()]}")

  defp category!(status) do
    n = System.unique_integer([:positive])

    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Cat #{n}"},
        "slug" => %{"en" => "cat-#{n}", lang() => "cat-#{n}"},
        "status" => status
      })

    category
  end

  test "shows the picked products as cards linking to their pages", %{conn: conn} do
    a = product!("Wall calendar")
    b = product!("Tote bag")
    main = product!("T-shirt") |> with_related([b.uuid, a.uuid])

    {:ok, view, html} = page(conn, main)

    assert has_element?(view, "#related-products")
    assert html =~ "You may also like"
    # A single-language site links without a locale segment.
    assert has_element?(view, ~s(#related-products a[href="/shop/product/wall-calendar"]))

    assert html |> String.split("Tote bag") |> length() > 1
    # merchant's order: the bag comes before the calendar
    {bag, _} = :binary.match(html, "Tote bag")
    {calendar, _} = :binary.match(html, "Wall calendar")
    assert bag < calendar
  end

  test "a page without a list renders no block", %{conn: conn} do
    main = product!("Plain")
    {:ok, view, html} = page(conn, main)

    refute has_element?(view, "#related-products")
    refute html =~ "You may also like"
  end

  test "drafts and products of a hidden category are not shown", %{conn: conn} do
    shown = product!("Visible one")
    draft = product!("Secret draft", %{"status" => "draft"})
    hidden = product!("Hidden category item", %{"category_uuid" => category!("hidden").uuid})
    main = product!("Main") |> with_related([draft.uuid, hidden.uuid, shown.uuid])

    {:ok, _view, html} = page(conn, main)

    assert html =~ "Visible one"
    refute html =~ "Secret draft"
    refute html =~ "Hidden category item"
  end

  test "no block when every picked product is hidden", %{conn: conn} do
    draft = product!("Only draft", %{"status" => "draft"})
    main = product!("Main") |> with_related([draft.uuid])

    {:ok, view, _html} = page(conn, main)
    refute has_element?(view, "#related-products")
  end

  test "the category fallback fills an empty page only when it is switched on", %{conn: conn} do
    category = category!("active")
    sibling = product!("Same shelf", %{"category_uuid" => category.uuid})
    main = product!("Main", %{"category_uuid" => category.uuid})

    {:ok, view, _html} = page(conn, main)
    refute has_element?(view, "#related-products")

    previous = Settings.get_setting("shop_related_fallback", "")
    Settings.update_setting("shop_related_fallback", "category")
    on_exit(fn -> Settings.update_setting("shop_related_fallback", previous) end)

    {:ok, view, html} = page(conn, main)
    assert has_element?(view, "#related-products")
    assert html =~ sibling.title["en"]
  end

  test "the block follows an edit of the list while the page is open", %{conn: conn} do
    a = product!("Added later")
    main = product!("Main")

    {:ok, view, _html} = page(conn, main)
    refute has_element?(view, "#related-products")

    with_related(main, [a.uuid])

    assert render(view) =~ "Added later"
  end

  test "the product itself is never in its own block", %{conn: conn} do
    main = product!("Self")
    main = with_related(main, [main.uuid])

    {:ok, view, _html} = page(conn, main)
    refute has_element?(view, "#related-products")
  end
end
