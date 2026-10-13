defmodule PhoenixKitEcommerce.Search.QueryTest do
  @moduledoc """
  `Search.Query` over a small shop indexed through the real indexer.

      Home
      |- Vases:  Red Ceramic Vase (Acme, gift, 20.00, was 25.00, size Large + colour Red)
      |          Green Vase Small (10.00, made to order, size Small)
      |- Bowls:  Blue Glass Bowl (Beta, 35.00)
      (none):    Wooden Spoon (gift, 5.00, description "handmade from oak")
                 Plant Stand (15.00, description "A stand for a vase")

  The typo fallback has its own module (it flips a global cache).
  """
  use PhoenixKitEcommerce.DataCase, async: true

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    disable_languages!()
    sample_shop!()
  end

  defp run(params, language \\ "en"), do: Query.run(params, language)
  defp ids(params, language \\ "en"), do: params |> run(language) |> Map.fetch!(:ids)

  test "browse lists every product, by position then title, with an exact count", t do
    result = run(%{})

    assert result.mode == :browse
    assert result.count == 5
    assert result.ids == [t.b, t.c, t.e, t.a, t.d]
    refute result.truncated?
  end

  test "full text finds a title match, and ranks it above a description match", t do
    result = run(%{q: "vase"})

    assert result.mode == :fulltext
    assert result.count == 3
    assert result.ids |> Enum.take(2) |> Enum.sort() == Enum.sort([t.a, t.c])
    assert List.last(result.ids) == t.e
  end

  test "full text reads vendor, tags, category names, option labels and descriptions", t do
    assert ids(%{q: "acme"}) == [t.a]
    assert ids(%{q: "gift"}) |> Enum.sort() == Enum.sort([t.a, t.d])
    assert ids(%{q: "bowls"}) == [t.b]
    assert ids(%{q: "large"}) == [t.a]
    assert ids(%{q: "colour"}) == [t.a]
    assert ids(%{q: "oak"}) == [t.d]
  end

  test "the language's stemming applies: a plural finds the singular", t do
    assert ids(%{q: "vases"}) |> Enum.sort() == Enum.sort([t.a, t.c, t.e])
  end

  test "a query uses the configuration of the requested language (en, de, fr)" do
    enable_languages!(["en", "de", "fr"])

    g =
      legacy_product!(%{
        "en" => "Plain Vase",
        "de" => "Rote Vasen",
        "fr" => "Grandes assiettes"
      })

    {:ok, _} = Indexer.reindex_items([g.uuid])

    assert ids(%{q: "Vase"}, "de") == [g.uuid]
    assert g.uuid in ids(%{q: "Vase"}, "en")
    assert ids(%{q: "assiette"}, "fr") == [g.uuid]
    refute g.uuid in ids(%{q: "assiette"}, "en")
  end

  test "hostile text never raises: quotes, operators, stop words, SQL, NUL, emoji, huge input" do
    hostile = [
      "\"",
      "\"unbalanced",
      "-",
      "or",
      "the",
      "!!!",
      "'; DROP TABLE phoenix_kit_shop_search_index; --",
      "%",
      "_",
      "\\",
      "((((",
      "a & | b",
      "a\0b",
      "😀",
      String.duplicate("a", 10_000),
      # 33 or more nested negations: `tsquery stack too small` (XX000) in
      # websearch_to_tsquery unless clean_q/1 neutralises the dashes
      String.duplicate("-", 40),
      String.duplicate("- ", 40) <> "a",
      String.duplicate("-(", 20)
    ]

    for q <- hostile do
      assert %{count: count, ids: ids} = run(%{q: q}), "q=#{inspect(q, limit: 20)}"
      assert is_integer(count) and is_list(ids)
    end

    assert run(%{}).count == 5
  end

  test "the cleaning happens before Postgres sees the text, not by rescuing its refusal" do
    # Without clean_q/1 both texts make Postgres raise; the rescue in the probe
    # would turn that into "no match" in :browse mode, which these assertions
    # tell apart from the real answers.
    assert %{mode: :browse, count: 5} = run(%{q: String.duplicate("-", 40)})
    assert %{mode: :fulltext} = run(%{q: "va\0se"})
    assert %{mode: :fulltext} = run(%{q: String.duplicate("- ", 40) <> "vase"})
  end

  test "clean_q/1 removes NUL bytes, trims, caps the length and turns blank into no query" do
    assert Query.clean_q("  vase ") == "vase"
    assert Query.clean_q("va\0se") == "vase"
    assert Query.clean_q("") == nil
    assert Query.clean_q("   ") == nil
    assert Query.clean_q("\0") == nil
    assert Query.clean_q(nil) == nil
    assert Query.clean_q(42) == nil
    assert String.length(Query.clean_q(String.duplicate("a", 300))) == 200
  end

  test "clean_q/1 keeps a dash that negates or joins a word and drops the others" do
    assert Query.clean_q("-vase") == "-vase"
    assert Query.clean_q("red -vase") == "red -vase"
    assert Query.clean_q("co-op") == "co-op"
    assert Query.clean_q("-") == nil
    assert Query.clean_q(String.duplicate("-", 40)) == nil
    assert Query.clean_q("a - b") == "a   b"
    assert Query.clean_q("-(") == "("
    refute Query.clean_q(String.duplicate("-(", 20)) =~ "-"
  end

  test "the category filter takes the whole branch", t do
    assert ids(%{category_id: t.home}) == [t.b, t.c, t.a]
    assert ids(%{category_id: t.vases}) == [t.c, t.a]
    assert ids(%{category_id: t.bowls}) == [t.b]
    assert ids(%{category_id: Ecto.UUID.generate()}) == []
  end

  test "price bounds are inclusive; vendor ignores case; flags can be true or false", t do
    assert ids(%{price_min: Decimal.new("10"), price_max: Decimal.new("20")}) == [t.c, t.e, t.a]
    assert ids(%{price_min: Decimal.new("20")}) == [t.b, t.a]
    assert ids(%{price_max: Decimal.new("5")}) == [t.d]
    assert ids(%{vendor: "acme"}) == [t.a]
    assert ids(%{on_sale: true}) == [t.a]
    assert ids(%{on_sale: false}) == [t.b, t.c, t.e, t.d]
    assert ids(%{made_to_order: true}) == [t.c]
    assert ids(%{made_to_order: false}) == [t.b, t.e, t.a, t.d]
  end

  test "a price-on-request product leaks no price through filters, sorts or the price facet", t do
    secret =
      legacy_product!(%{"en" => "Secret Vase"}, %{
        price: "777.00",
        compare_at_price: "900.00",
        metadata: %{"_price_display" => %{"on_request" => true}}
      })

    {:ok, _} = Indexer.reindex_items([secret.uuid])

    row = Query.entry(secret.uuid, "en")
    assert row.price == nil and row.compare_at_price == nil and row.discount_pct == nil
    assert row.on_sale == false

    # still listed ...
    assert secret.uuid in ids(%{})
    assert secret.uuid in ids(%{q: "secret"})

    # ... but invisible to every price device
    refute secret.uuid in ids(%{price_min: Decimal.new("700")})
    refute secret.uuid in ids(%{price_max: Decimal.new("800")})
    assert {_min, max} = run(%{}).facets.price
    assert Decimal.equal?(max, Decimal.new("35.00"))
    assert List.last(ids(%{sort: :price_desc})) == secret.uuid
    assert List.last(ids(%{sort: :price_asc})) == secret.uuid
    assert hd(ids(%{sort: :price_desc})) == t.b
  end

  test "options are OR within a key and AND across keys", t do
    assert ids(%{options: %{"size" => ["large", "small"]}}) == [t.c, t.a]
    assert ids(%{options: %{"size" => ["large"], "colour" => ["red"]}}) == [t.a]
    assert ids(%{options: %{"size" => ["large"], "colour" => ["blue"]}}) == []
    assert ids(%{options: %{"nonsense" => ["x"]}}) == []
  end

  test "filters combine with each other and with a query", t do
    assert ids(%{category_id: t.vases, price_max: Decimal.new("15")}) == [t.c]
    assert ids(%{q: "vase", category_id: t.vases}) |> Enum.sort() == Enum.sort([t.a, t.c])
    assert ids(%{q: "vase", vendor: "nobody"}) == []
  end

  test "sorts", t do
    assert ids(%{sort: :price_asc}) == [t.d, t.c, t.e, t.a, t.b]
    assert ids(%{sort: :price_desc}) == [t.b, t.a, t.e, t.c, t.d]
    assert ids(%{sort: :discount_desc}) == [t.a, t.b, t.c, t.e, t.d]
  end

  test "newest sorts by the product's creation time", t do
    for {id, days} <- [{t.a, 0}, {t.b, 1}, {t.c, 2}, {t.d, 3}, {t.e, 4}] do
      Repo.query!(
        """
        UPDATE phoenix_kit_shop_search_index
        SET item_inserted_at = now() - ($2::int * interval '1 day') WHERE item_uuid = $1
        """,
        [Ecto.UUID.dump!(id), days]
      )
    end

    assert ids(%{sort: :newest}) == [t.a, t.b, t.c, t.d, t.e]
  end

  test "pages keep their order and the count stays exact", t do
    assert run(%{limit: 2, offset: 0}) |> Map.take([:ids, :count]) == %{ids: [t.b, t.c], count: 5}
    assert run(%{limit: 2, offset: 2}) |> Map.take([:ids, :count]) == %{ids: [t.e, t.a], count: 5}
    assert run(%{limit: 2, offset: 4}) |> Map.take([:ids, :count]) == %{ids: [t.d], count: 5}
    assert run(%{limit: 2, offset: 6}) |> Map.take([:ids, :count]) == %{ids: [], count: 5}
  end

  test "facets describe the matched set", t do
    facets = run(%{}).facets

    assert facets.categories == %{t.vases => 2, t.bowls => 1}
    assert facets.vendors == %{"Acme" => 1, "Beta" => 1}
    assert facets.on_sale == 1
    assert facets.made_to_order == 1
    assert {min, max} = facets.price
    assert Decimal.equal?(min, Decimal.new("5.00"))
    assert Decimal.equal?(max, Decimal.new("35.00"))

    assert Enum.map(facets.options, &{&1.pair, &1.label, &1.set_label, &1.count}) == [
             {"colour:red", "Red", "Colour", 1},
             {"size:large", "Large", "Size", 1},
             {"size:small", "Small", "Size", 1}
           ]
  end

  test "facets follow the filters", t do
    facets = run(%{category_id: t.vases}).facets

    assert facets.categories == %{t.vases => 2}
    assert facets.vendors == %{"Acme" => 1}
    assert facets.on_sale == 1
    assert {min, max} = facets.price
    assert Decimal.equal?(min, Decimal.new("10.00"))
    assert Decimal.equal?(max, Decimal.new("20.00"))

    empty = run(%{category_id: Ecto.UUID.generate()}).facets
    assert empty.categories == %{}
    assert empty.price == nil
    assert empty.options == []
  end

  test "cursors are opaque offsets, and anything else is refused" do
    assert Query.decode_cursor(Query.encode_cursor(40)) == {:ok, 40}
    assert Query.decode_cursor(nil) == {:ok, 0}
    assert Query.decode_cursor("") == {:ok, 0}

    for bad <- [
          "!!!",
          "x",
          Base.url_encode64("o:-1", padding: false),
          Base.url_encode64("o:10001", padding: false),
          Base.url_encode64("x:5", padding: false),
          Base.url_encode64("o:5x", padding: false),
          String.duplicate("A", 5_000)
        ] do
      assert Query.decode_cursor(bad) == :error, "cursor #{inspect(bad, limit: 20)}"
    end

    assert Query.decode_cursor(Query.encode_cursor(10_000)) == {:ok, 10_000}
  end

  test "next_cursor/3 exists only while there is a next page the cursor can reach" do
    assert Query.next_cursor(0, 20, 45) == Query.encode_cursor(20)
    assert Query.next_cursor(40, 20, 45) == nil
    assert Query.next_cursor(0, 20, 20) == nil
    assert Query.next_cursor(9_990, 20, 50_000) == nil
  end

  test "category_counts/1 counts the products directly in each category", t do
    assert Query.category_counts("en") == %{t.vases => 2, t.bowls => 1}
    assert Query.category_counts("de") == %{}
  end

  test "similar/2 ranks the same category first, then shared options and tags, and never the product itself",
       t do
    base = Query.entry(t.a, "en")

    assert base.item_uuid == t.a
    assert Query.similar(base, 10) == [t.c, t.d]
    assert Query.similar(base, 1) == [t.c]

    assert Query.entry(Ecto.UUID.generate(), "en") == nil
    assert Query.entry(t.a, "de") == nil

    # A product with nothing in common with anything has no similar products.
    assert Query.similar(Query.entry(t.b, "en"), 10) == []
  end
end
