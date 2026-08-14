defmodule PhoenixKitEcommerce.EmptySlugTest do
  @moduledoc """
  An unromanizable title must not write an empty slug.

  `Slug.slugify/2` falls back to `""` for scripts it cannot romanize (CJK,
  Arabic, emoji), and the unique index on `extract_primary_slug(slug)` is
  partial only on `IS NOT NULL` — so a written `""` was *enforced*, and a
  shop's SECOND product with a CJK-only title could not be inserted at all:

      ERROR: duplicate key value violates unique constraint
             "idx_shop_products_slug_primary"
      DETAIL: Key (extract_primary_slug(slug))=() already exists.

  The generator now keeps only non-empty results and scrubs empties already
  in the map, so legacy rows self-heal on their next save —
  `extract_primary_slug('{}')` is NULL, which drops the row out of the
  partial index instead of squatting on the `""` key.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias Ecto.Changeset
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  defp product_slugs(title_map, base \\ %Product{}) do
    base
    |> Product.changeset(%{title: title_map, price: 100})
    |> Changeset.get_field(:slug)
  end

  describe "the generator" do
    test "writes no key for an unromanizable title instead of an empty slug" do
      # The map key is the store's language, not the script of the text — an
      # English-keyed shop entering CJK text is the everyday route here.
      assert product_slugs(%{"en" => "日本語"}) == %{}
    end

    test "keeps only the romanizable languages of a mixed title" do
      assert product_slugs(%{"en" => "Nihongo", "ja" => "日本語"}) == %{"en" => "nihongo"}
    end

    test "categories behave the same" do
      slugs =
        %Category{}
        |> Category.changeset(%{name: %{"en" => "日本語"}})
        |> Changeset.get_field(:slug)

      assert slugs == %{}
    end
  end

  describe "against the real index" do
    test "a second CJK-only product inserts — the bug this fixes" do
      for title <- ["日本語", "別の話"] do
        {:ok, _} =
          %Product{}
          |> Product.changeset(%{title: %{"en" => title}, price: 100})
          |> Repo.insert()
      end
    end

    test "a legacy row holding an empty slug self-heals on its next save" do
      # Written the way pre-fix code wrote it, bypassing the changeset.
      legacy =
        Repo.insert!(%Product{
          title: %{"en" => "日本語"},
          slug: %{"en" => ""},
          price: Decimal.new(100)
        })

      {:ok, healed} = legacy |> Product.changeset(%{}) |> Repo.update()

      assert healed.slug == %{}

      # And with the "" key vacated, a CJK-only product can insert again.
      {:ok, _} =
        %Product{}
        |> Product.changeset(%{title: %{"en" => "別の話"}, price: 100})
        |> Repo.insert()
    end
  end
end
