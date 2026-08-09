defmodule PhoenixKitEcommerce.SlugifyTest do
  @moduledoc """
  This rule has drifted between Product and Category twice — Cyrillic, then
  German — and each time the fix landed on one schema only, so a title that
  worked as a product silently broke as a category. The parity test at the
  bottom is the one that would have caught both.
  """
  # DataCase rather than ExUnit.Case: the parity check runs Category's changeset,
  # which reads a language setting and therefore needs a connection.
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Slugify

  describe "German" do
    test "expands umlauts and ß rather than stripping them" do
      # Core's NFD pass decomposes ö to o and DROPS ß, giving "gro-e-fu-ball".
      assert Slugify.slugify("Größe Fußball") == "groesse-fussball"
    end

    test "handles uppercase forms, which appear before core lowercases" do
      assert Slugify.slugify("Öl") == "oel"
      assert Slugify.slugify("Ähre") == "aehre"
      assert Slugify.slugify("ÜBER") == "ueber"
    end
  end

  describe "Cyrillic" do
    test "transliterates rather than producing an empty slug" do
      # An ASCII-only slugifier stripped every character and stored "".
      assert Slugify.slugify("Видеопродакшн") == "videoprodakshn"
      assert Slugify.slugify("Цветокоррекция") == "tsvetokorrektsiya"
    end
  end

  describe "ordinary input" do
    test "lowercases and hyphenates" do
      assert Slugify.slugify("Corporate Video") == "corporate-video"
    end

    test "non-binary input yields an empty slug rather than raising" do
      assert Slugify.slugify(nil) == ""
      assert Slugify.slugify(42) == ""
    end
  end

  describe "product/category parity" do
    test "both schemas slug identically for every case that has drifted" do
      # Product exposes slugify/1 publicly; Category's is private, so parity is
      # asserted through the changeset that derives the slug.
      for title <- ["Größe Fußball", "Видеопродакшн", "Corporate Video", "Öl"] do
        product_slug = Product.slugify(title)

        category_slug =
          %Category{}
          |> Category.changeset(%{"name" => %{"en" => title}})
          |> Ecto.Changeset.get_change(:slug)
          |> case do
            %{"en" => slug} -> slug
            other -> other
          end

        assert product_slug == category_slug,
               "#{title}: product=#{inspect(product_slug)} category=#{inspect(category_slug)}"
      end
    end
  end
end
