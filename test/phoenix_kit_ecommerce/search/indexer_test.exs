defmodule PhoenixKitEcommerce.Search.IndexerTest do
  @moduledoc """
  The indexer on the legacy product source (no catalogue needed). The
  catalogue-specific cases are in `indexer_catalogue_test.exs`.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Test.Repo

  defp rows(uuid) do
    Repo.all(
      from(e in Entry,
        where: e.item_uuid == ^uuid,
        order_by: e.language,
        select: {e.language, e.title}
      )
    )
  end

  test "indexes a listed product once per enabled language, with the default title as fallback" do
    enable_languages!(["en", "de"])
    product = legacy_product!(%{"en" => "Red Vase"})

    assert {:ok, %{indexed: 2, removed: 0}} = Indexer.reindex_items([product.uuid])

    assert rows(product.uuid) == [{"de", "Red Vase"}, {"en", "Red Vase"}]
  end

  test "a translated title is indexed in its own language" do
    enable_languages!(["en", "de"])
    product = legacy_product!(%{"en" => "Red Vase", "de" => "Rote Vasen"})

    {:ok, _} = Indexer.reindex_items([product.uuid])

    assert rows(product.uuid) == [{"de", "Rote Vasen"}, {"en", "Red Vase"}]

    # The german document is stemmed with the german configuration: "Vase" finds "Vasen".
    %{rows: [[count]]} =
      Repo.query!("""
      SELECT count(*) FROM phoenix_kit_shop_search_index
      WHERE language = 'de' AND document @@ websearch_to_tsquery('german', 'Vase')
      """)

    assert count == 1
  end

  test "a draft, an archived and a hidden-category product get no rows" do
    hidden = legacy_category!(%{"en" => "Hidden"}, %{status: "hidden"})
    draft = legacy_product!(%{"en" => "Draft"}, %{status: "draft"})
    archived = legacy_product!(%{"en" => "Archived"}, %{status: "archived"})
    in_hidden = legacy_product!(%{"en" => "In hidden"}, %{category_uuid: hidden.uuid})
    listed = legacy_product!(%{"en" => "Listed"})

    ids = [draft.uuid, archived.uuid, in_hidden.uuid, listed.uuid]
    assert {:ok, %{indexed: 1, removed: 0}} = Indexer.reindex_items(ids)

    assert rows(draft.uuid) == []
    assert rows(archived.uuid) == []
    assert rows(in_hidden.uuid) == []
    assert [{"en", "Listed"}] = rows(listed.uuid)
  end

  test "the row carries the category chain, options, price and sale flags" do
    root = legacy_category!(%{"en" => "Home"})
    leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})

    product =
      legacy_product!(%{"en" => "Red Vase"}, %{
        category_uuid: leaf.uuid,
        vendor: "Acme",
        tags: ["gift"],
        price: "20.00",
        compare_at_price: "25.00",
        made_to_order: true,
        metadata: %{"_option_values" => %{"size" => ["Large"]}}
      })

    {:ok, _} = Indexer.reindex_items([product.uuid])

    entry = Repo.one!(from(e in Entry, where: e.item_uuid == ^product.uuid))

    assert entry.category_uuid == leaf.uuid
    assert entry.category_path == ["Home", "Vases"]
    assert entry.category_path_uuids == [root.uuid, leaf.uuid]
    assert entry.vendor == "Acme"
    assert entry.tags == ["gift"]
    assert entry.option_pairs == ["size:large"]
    assert entry.option_labels == %{"size" => "Size", "size:large" => "Large"}
    assert entry.made_to_order
    assert entry.on_sale
    assert Decimal.equal?(entry.price, Decimal.new("20.00"))
    assert Decimal.equal?(entry.discount_pct, Decimal.new("20.00"))
    assert entry.title_trgm == "red vase"
  end

  test "a product that stops being listed loses its rows on the next reindex" do
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])
    assert [{"en", "Red Vase"}] = rows(product.uuid)

    {:ok, _} = Shop.update_product(product, %{status: "draft"})

    assert {:ok, %{indexed: 0, removed: 1}} = Indexer.reindex_items([product.uuid])
    assert rows(product.uuid) == []
  end

  test "a deleted product loses its rows" do
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])

    {:ok, _} = Shop.delete_product(product)

    assert {:ok, %{indexed: 0, removed: 1}} = Indexer.reindex_items([product.uuid])
    assert rows(product.uuid) == []
  end

  test "reindex_items/1 touches only the ids it is given" do
    a = legacy_product!(%{"en" => "Alpha Vase"})
    b = legacy_product!(%{"en" => "Beta Vase"})
    {:ok, _} = Indexer.reindex_items([a.uuid, b.uuid])

    {:ok, _} = Shop.update_product(a, %{title: %{"en" => "Alpha Bowl"}})
    {:ok, _} = Shop.update_product(b, %{title: %{"en" => "Beta Bowl"}})

    {:ok, _} = Indexer.reindex_items([a.uuid])

    assert [{"en", "Alpha Bowl"}] = rows(a.uuid)
    assert [{"en", "Beta Vase"}] = rows(b.uuid)
  end

  test "rows of a language that is no longer enabled are removed" do
    enable_languages!(["en", "de"])
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])
    assert length(rows(product.uuid)) == 2

    enable_languages!(["en"])

    assert {:ok, %{indexed: 1, removed: 1}} = Indexer.reindex_items([product.uuid])
    assert rows(product.uuid) == [{"en", "Red Vase"}]
  end

  test "malformed ids and an empty list are harmless" do
    assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items([])
    assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items(["nope", nil, 3])
  end

  describe "rebuild/0" do
    test "indexes every listed product and removes rows nobody owns any more" do
      listed = legacy_product!(%{"en" => "Listed"})
      _draft = legacy_product!(%{"en" => "Draft"}, %{status: "draft"})

      Repo.query!(
        """
        INSERT INTO phoenix_kit_shop_search_index
          (item_uuid, language, title, title_trgm, document, indexed_at)
        VALUES ($1, 'en', 'Ghost', 'ghost', to_tsvector('simple', 'ghost'), now() - interval '1 day')
        """,
        [Ecto.UUID.bingenerate()]
      )

      assert {:ok, %{products: 2, indexed: 1, removed: 1}} = Indexer.rebuild()

      titles = Repo.all(from(e in Entry, select: e.title))
      assert titles == ["Listed"]
      assert [{"en", "Listed"}] = rows(listed.uuid)
    end

    test "upserts in place: the row of a product that stays listed keeps its primary key" do
      product = legacy_product!(%{"en" => "Red Vase"})
      {:ok, _} = Indexer.reindex_items([product.uuid])
      before = Repo.one!(from(e in Entry, where: e.item_uuid == ^product.uuid, select: e.uuid))

      {:ok, _} = Shop.update_product(product, %{title: %{"en" => "Red Bowl"}})
      assert {:ok, %{indexed: 1, removed: 0}} = Indexer.rebuild()

      after_rebuild =
        Repo.one!(
          from(e in Entry, where: e.item_uuid == ^product.uuid, select: {e.uuid, e.title})
        )

      assert after_rebuild == {before, "Red Bowl"}
    end

    test "on an empty shop it empties the index (the shop really is empty)" do
      Repo.query!(
        """
        INSERT INTO phoenix_kit_shop_search_index
          (item_uuid, language, title, title_trgm, document, indexed_at)
        VALUES ($1, 'en', 'Ghost', 'ghost', to_tsvector('simple', 'ghost'), now() - interval '1 day')
        """,
        [Ecto.UUID.bingenerate()]
      )

      assert {:ok, %{products: 0, indexed: 0, removed: 1}} = Indexer.rebuild()
    end
  end

  describe "status/0 and empty?/0" do
    test "count the rows per language" do
      enable_languages!(["en", "de"])
      assert Indexer.empty?()
      assert %{rows: 0, languages: %{}} = Indexer.status()

      product = legacy_product!(%{"en" => "Red Vase"})
      {:ok, _} = Indexer.reindex_items([product.uuid])

      refute Indexer.empty?()
      assert %{rows: 2, languages: %{"en" => 1, "de" => 1}, trigram: trigram} = Indexer.status()
      assert is_boolean(trigram)
    end
  end
end
