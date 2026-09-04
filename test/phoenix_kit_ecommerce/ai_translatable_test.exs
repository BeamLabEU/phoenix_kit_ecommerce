defmodule PhoenixKitEcommerce.AITranslatableTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
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
          Sandbox.allow(repo(), parent, self())
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

  test "an extremely long title produces a slug capped at a word boundary" do
    product = create_product()
    long = String.duplicate("vase ", 2000)

    {:ok, updated} = AITranslatable.put_translation(product, "fr", %{"title" => long}, [])

    assert String.length(updated.slug["fr"]) <= 60
    refute String.ends_with?(updated.slug["fr"], "-")
  end

  test "only the head segment before '|' is used for the slug" do
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(
        product,
        "fr",
        %{"title" => "Vase en Bois | Decoration Maison | Cadeau"},
        []
      )

    assert updated.slug["fr"] == "vase-en-bois"
  end

  test "a spaced-dash split keeps only the head segment for the slug" do
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois - Cadeau"}, [])

    assert updated.slug["fr"] == "vase-en-bois"

    product2 = create_product(%{title: %{"en" => "Other Vase"}})

    {:ok, updated2} =
      AITranslatable.put_translation(product2, "fr", %{"title" => "Vase Cadeau – Special"}, [])

    assert updated2.slug["fr"] == "vase-cadeau"
  end

  test "a long head segment is capped at a word boundary, not mid-word" do
    product = create_product()
    # 7 words of 9 chars each (with separating spaces) exceeds 60 chars
    words = for _ <- 1..7, do: "wordword9"
    head = Enum.join(words, " ")

    {:ok, updated} = AITranslatable.put_translation(product, "fr", %{"title" => head}, [])

    slug = updated.slug["fr"]
    assert String.length(slug) <= 60
    refute String.ends_with?(slug, "-")
    # no partial word: every remaining word appears in full
    assert Enum.all?(String.split(slug, "-"), &(&1 in ["wordword9"] or &1 == ""))
  end

  test "a cut landing exactly on a word boundary keeps the whole prefix intact" do
    product = create_product()
    # Five 9-char words + one 10-char word joined by 5 dashes = 60 chars
    # exactly, so the char right after the cut is "-" (a clean boundary) —
    # the last (10-char) word must NOT be dropped as if it were partial.
    words = List.duplicate("aaaaaaaaa", 5) ++ ["aaaaaaaaaa"]
    head = Enum.join(words, " ")
    assert String.length(Enum.join(words, "-")) == 60

    title = head <> " extra tail words that get cut off"

    {:ok, updated} = AITranslatable.put_translation(product, "fr", %{"title" => title}, [])

    assert updated.slug["fr"] == Enum.join(words, "-")
  end

  test "a numeric identity tail is carried from the default-language slug" do
    product =
      create_product(%{
        title: %{"en" => "Wooden Vase"},
        slug: %{"en" => "wooden-vase-22153"}
      })

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"}, [])

    assert updated.slug["fr"] == "vase-en-bois-22153"
  end

  test "no tail is carried when the default-language slug has none" do
    product = create_product(%{title: %{"en" => "Wooden Vase"}, slug: %{"en" => "wooden-vase"}})

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"}, [])

    assert updated.slug["fr"] == "vase-en-bois"
  end

  test "no tail is carried when the default-language slug ends in a collision suffix" do
    product = create_product(%{title: %{"en" => "Wooden Vase"}, slug: %{"en" => "wooden-vase-2"}})

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"}, [])

    assert updated.slug["fr"] == "vase-en-bois"
  end

  test "the base already ending in the tail is not duplicated" do
    product =
      create_product(%{
        title: %{"en" => "Wooden Vase 22153"},
        slug: %{"en" => "wooden-vase-22153"}
      })

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois 22153"}, [])

    assert updated.slug["fr"] == "vase-en-bois-22153"
  end

  test "an empty head segment falls back to the full title" do
    product = create_product()

    # A head segment made only of characters that slugify to "" (e.g. CJK)
    # falls back to the full (translated) title for slugification.
    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "測試 | Vase en Bois"}, [])

    assert updated.slug["fr"] == "vase-en-bois"
  end

  describe "regenerate_slug/2" do
    test "recomputes the slug from the current title, even when one already exists" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "fr" => "Vieux Nom"},
          slug: %{"en" => "wooden-vase", "fr" => "vieux-nom"}
        })

      assert {:ok, %{old: "vieux-nom", new: "vieux-nom"}} =
               AITranslatable.regenerate_slug(product.uuid, "fr")

      # title unchanged -> slug recomputed to the same value
      fresh = repo().get(Product, product.uuid)
      assert fresh.slug["fr"] == "vieux-nom"
    end

    test "returns the old and new slug when the title changed" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "fr" => "Nouveau Titre"},
          slug: %{"en" => "wooden-vase", "fr" => "ancien-slug"}
        })

      assert {:ok, %{old: "ancien-slug", new: "nouveau-titre"}} =
               AITranslatable.regenerate_slug(product.uuid, "fr")

      fresh = repo().get(Product, product.uuid)
      assert fresh.slug["fr"] == "nouveau-titre"
    end

    test "returns {:error, :no_title} when the language has no title" do
      product = create_product()

      assert {:error, :no_title} = AITranslatable.regenerate_slug(product.uuid, "fr")
    end

    test "returns {:error, :resource_not_found} for an unknown uuid" do
      assert {:error, :resource_not_found} =
               AITranslatable.regenerate_slug(Ecto.UUID.generate(), "fr")
    end

    test "dry_run: true computes old/new without writing anything" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "fr" => "Nouveau Titre"},
          slug: %{"en" => "wooden-vase", "fr" => "ancien-slug"}
        })

      assert {:ok, %{old: "ancien-slug", new: "nouveau-titre"}} =
               AITranslatable.regenerate_slug(product.uuid, "fr", dry_run: true)

      # slug in the DB is untouched by the dry run
      fresh = repo().get(Product, product.uuid)
      assert fresh.slug["fr"] == "ancien-slug"
    end
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
