defmodule PhoenixKitEcommerce.AITranslatableTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.Product

  defp create_product(attrs \\ %{}) do
    base = %{
      title: %{"en" => "Wooden Vase"},
      description: %{"en" => "A nice vase"},
      seo_title: %{"en" => "Buy Wooden Vase"},
      price: Decimal.new("10.00"),
      status: "active"
    }

    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  test "registered as shop_product" do
    assert {"shop_product", AITranslatable} in PhoenixKitEcommerce.ai_translatables()
  end

  test "fetch/2 loads by uuid, errors on miss" do
    product = create_product()
    assert {:ok, %Product{}} = AITranslatable.fetch("shop_product", product.uuid)

    assert {:error, :resource_not_found} =
             AITranslatable.fetch("shop_product", Ecto.UUID.generate())
  end

  test "source_fields/2 maps schema fields to prompt vocabulary, skipping empties" do
    product = create_product()
    fields = AITranslatable.source_fields(product, "en")

    assert fields["title"] == "Wooden Vase"
    assert fields["description"] == "A nice vase"
    assert fields["seo_title"] == "Buy Wooden Vase"
    # body_html empty ⇒ no "body" key
    refute Map.has_key?(fields, "body")
  end

  test "put_translation/4 merges fields and generates a local slug once" do
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(
        product,
        "fr",
        %{"title" => "Vase en Bois", "description" => "Un joli vase", "seo_title" => "Acheter"},
        []
      )

    assert updated.title["fr"] == "Vase en Bois"
    assert updated.description["fr"] == "Un joli vase"
    assert updated.seo_title["fr"] == "Acheter"
    # slug generated locally from translated title
    assert updated.slug["fr"] == "vase-en-bois"
    # sibling language untouched
    assert updated.title["en"] == "Wooden Vase"

    # re-translation must NOT change the existing slug
    {:ok, again} =
      AITranslatable.put_translation(updated, "fr", %{"title" => "Vase Nouveau"}, [])

    assert again.title["fr"] == "Vase Nouveau"
    assert again.slug["fr"] == "vase-en-bois"
  end

  test "an AI-provided slug field is ignored entirely" do
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(
        product,
        "fr",
        %{"title" => "Vase", "slug" => "../../evil"},
        []
      )

    assert updated.slug["fr"] == "vase"
  end

  test "slug collides within the language get suffixed" do
    _other = create_product(%{title: %{"en" => "Other"}, slug: %{"fr" => "vase-en-bois"}})
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"}, [])

    assert updated.slug["fr"] == "vase-en-bois-2"
  end

  test "concurrent translations of two languages both survive" do
    product = create_product()
    parent = self()

    tasks =
      for {lang, title} <- [{"fr", "Vase FR"}, {"de", "Vase DE"}] do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(repo(), parent, self())
          AITranslatable.put_translation(product, lang, %{"title" => title}, [])
        end)
      end

    Enum.each(tasks, &Task.await/1)

    fresh = repo().get(Product, product.uuid)
    assert fresh.title["fr"] == "Vase FR"
    assert fresh.title["de"] == "Vase DE"
  end

  test "accented Latin titles transliterate in the slug" do
    product = create_product()

    {:ok, fr} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Étagère décorative"}, [])

    assert fr.slug["fr"] == "etagere-decorative"

    {:ok, de} = AITranslatable.put_translation(product, "de", %{"title" => "Größe Fußball"}, [])
    assert de.slug["de"] == "groesse-fussball"
  end

  test "Cyrillic titles transliterate to a readable slug" do
    product = create_product()

    {:ok, ru} = AITranslatable.put_translation(product, "ru", %{"title" => "Ваза Деревянная"}, [])
    assert ru.slug["ru"] == "vaza-derevyannaya"
  end

  test "an extremely long title produces a capped slug" do
    product = create_product()
    long = String.duplicate("vase ", 2000)

    {:ok, updated} = AITranslatable.put_translation(product, "fr", %{"title" => long}, [])

    assert String.length(updated.slug["fr"]) <= 80
  end

  test "ensure_prompt/0 is idempotent (slug must match create_prompt's name-derived slug)" do
    case AITranslatable.ensure_prompt() do
      {:ok, uuid1} ->
        assert {:ok, ^uuid1} = AITranslatable.ensure_prompt()

      {:error, :ai_not_installed} ->
        # AI plugin/schema not present in this test env — nothing to assert.
        :ok
    end
  end

  test "blank translations are rejected" do
    product = create_product()

    assert {:error, :no_translated_fields} =
             AITranslatable.put_translation(product, "fr", %{"title" => "  "}, [])
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
