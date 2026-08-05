defmodule PhoenixKitEcommerce.Regression.ImportUpsertTest do
  @moduledoc """
  A re-import must not delete what the feed says nothing about.

  `upsert_product/1` merges localized fields but replaced every other field
  wholesale, and the importers always supply the full attr set — blank cells
  included. So a routine second import of a minimal CSV wiped translations in
  languages the file never mentioned, plus the admin's option pricing, image
  mappings and custom metadata.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop

  defp lang, do: PhoenixKitEcommerce.Translations.default_language()

  defp existing_product(extra \\ %{}) do
    suffix = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{lang() => "Planter", "de" => "Blumentopf"},
            "slug" => %{lang() => "planter-#{suffix}"},
            "body_html" => %{lang() => "<p>Handmade</p>", "de" => "<p>Handgemacht</p>"},
            "seo_title" => %{lang() => "Planter", "de" => "Blumentopf"},
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "vendor" => "Studio Ceramica",
            "images" => [%{"src" => "https://cdn.example/legacy.jpg"}],
            "featured_image" => "https://cdn.example/legacy.jpg"
          },
          extra
        )
      )

    product
  end

  # What a minimal Shopify row transforms into: every field present, the
  # unfilled ones blank.
  defp minimal_reimport(product, overrides \\ %{}) do
    Map.merge(
      %{
        "slug" => %{lang() => product.slug[lang()]},
        "title" => %{lang() => "Planter"},
        "body_html" => %{},
        "description" => %{},
        "seo_title" => %{},
        "seo_description" => %{},
        "vendor" => nil,
        "price" => Decimal.new("12.00"),
        "images" => [],
        "featured_image" => nil,
        "metadata" => %{}
      },
      overrides
    )
  end

  test "a blank cell does not erase translations in other languages" do
    product = existing_product()

    {:ok, updated, :updated} = Shop.upsert_product(minimal_reimport(product))

    assert updated.body_html["de"] == "<p>Handgemacht</p>",
           "a blank Body (HTML) cell erased every language, not just the imported one"

    assert updated.body_html[lang()] == "<p>Handmade</p>"
    assert updated.seo_title["de"] == "Blumentopf"
    assert updated.title["de"] == "Blumentopf", "an untouched language must survive"
  end

  test "a supplied translation still wins over the stored one" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(minimal_reimport(product, %{"body_html" => %{lang() => "<p>New</p>"}}))

    assert updated.body_html[lang()] == "<p>New</p>"
    assert updated.body_html["de"] == "<p>Handgemacht</p>"
  end

  test "a re-import keeps metadata the feed knows nothing about" do
    product =
      existing_product(%{
        "metadata" => %{
          "custom" => %{"care" => "wipe clean"},
          "_price_modifiers" => %{"size" => %{"large" => "5.00"}},
          "_image_mappings" => %{"red" => "img-1"}
        }
      })

    {:ok, updated, :updated} =
      Shop.upsert_product(
        minimal_reimport(product, %{"metadata" => %{"_option_values" => %{"size" => ["large"]}}})
      )

    assert updated.metadata["custom"] == %{"care" => "wipe clean"}
    assert updated.metadata["_price_modifiers"] == %{"size" => %{"large" => "5.00"}}
    assert updated.metadata["_image_mappings"] == %{"red" => "img-1"}
    assert updated.metadata["_option_values"] == %{"size" => ["large"]}, "incoming keys still win"
  end

  test "a feed with no image columns does not clear the product's images" do
    product = existing_product()

    {:ok, updated, :updated} = Shop.upsert_product(minimal_reimport(product))

    assert updated.images == [%{"src" => "https://cdn.example/legacy.jpg"}]
    assert updated.featured_image == "https://cdn.example/legacy.jpg"
    assert updated.vendor == "Studio Ceramica"
  end

  test "a feed that does carry images replaces them" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(
        minimal_reimport(product, %{
          "images" => [%{"src" => "https://cdn.example/new.jpg"}],
          "featured_image" => "https://cdn.example/new.jpg",
          "vendor" => "Other Studio"
        })
      )

    assert updated.images == [%{"src" => "https://cdn.example/new.jpg"}]
    assert updated.featured_image == "https://cdn.example/new.jpg"
    assert updated.vendor == "Other Studio"
  end

  test "fields the feed does own are still updated" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(minimal_reimport(product, %{"status" => "draft"}))

    assert Decimal.equal?(updated.price, Decimal.new("12.00"))
    assert updated.status == "draft"
  end

  test "an attrs map with no metadata key stays string-keyed" do
    product = existing_product()

    # Ecto refuses a params map that mixes atom and string keys.
    assert {:ok, _updated, :updated} =
             Shop.upsert_product(%{
               "slug" => %{lang() => product.slug[lang()]},
               "title" => %{lang() => "Planter"},
               "price" => Decimal.new("12.00")
             })
  end

  @tag :requires_core_transliteration
  test "a Cyrillic title yields a stable slug, so a re-import matches it" do
    suffix = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{lang() => "Кашпо #{suffix}"},
        "price" => Decimal.new("10.00"),
        "status" => "active"
      })

    slug = product.slug[lang()]
    assert slug =~ "kashpo", "a Cyrillic title used to slugify to an empty string"

    {:ok, _same, :updated} =
      Shop.upsert_product(%{
        "slug" => %{lang() => slug},
        "title" => %{lang() => "Кашпо #{suffix}"},
        "price" => Decimal.new("11.00")
      })
  end
end
