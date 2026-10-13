defmodule PhoenixKitEcommerce.API.Public.SearchTest do
  @moduledoc """
  The two search handlers, called the way the executor calls them:
  `apply(Search, :search_products, [input, ctx])`.

  Needs a core with the shop API (`PhoenixKit.API.Actor`, `Validator`).
  `async: false`: Billing's currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Validator
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Public.Search
  alias PhoenixKitEcommerce.Search.Indexer

  setup do
    disable_languages!()
    currencies!()
    sample_shop!()
  end

  defp ctx(overrides \\ []) do
    ip = "10.0.#{rem(System.unique_integer([:positive]), 250)}.#{:rand.uniform(250)}"

    Map.merge(
      %{
        # struct/2, not a %Actor{} literal: a literal is expanded at compile time
        # and fails the whole test run on a core without PhoenixKit.API.Actor.
        actor: struct(Actor, kind: :anonymous, ip: ip, cart_token_hash: nil),
        scopes: [],
        audience: :public,
        language: "en",
        currency: nil,
        hosts: ["shop.test"],
        base_url: "https://shop.test",
        request_id: "req-1",
        dry_run?: false
      },
      Map.new(overrides)
    )
  end

  defp search!(input, overrides \\ []) do
    assert {:ok, out} = Search.search_products(input, ctx(overrides))
    out
  end

  defp batch!(input, overrides \\ []) do
    assert {:ok, out} = Search.search_products_batch(input, ctx(overrides))
    out
  end

  defp item_ids(out), do: Enum.map(out["items"], & &1["id"])

  test "answers with cards, facets, an exact count and the language and currency used", t do
    out = search!(%{"q" => "vase"})

    assert out["count"] == 3
    assert out["match_mode"] == "fulltext"
    assert out["language"] == "en"
    assert out["currency"] == "USD"
    assert item_ids(out) |> Enum.take(2) |> Enum.sort() == Enum.sort([t.a, t.c])
    assert List.last(item_ids(out)) == t.e
    refute Map.has_key?(out, "next_cursor")
    refute Map.has_key?(out, "warnings")

    item = Enum.find(out["items"], &(&1["id"] == t.a))
    assert item["title"] == "Red Ceramic Vase"
    assert item["price"] == %{"amount" => "20.00", "currency" => "USD"}
    assert item["url"] =~ "https://shop.test/"

    assert [%{"id" => vases, "name" => "Vases", "count" => 2}] =
             Enum.filter(out["facets"]["categories"], &(&1["name"] == "Vases"))

    assert vases == t.vases
    assert %{"value" => "Acme", "count" => 1} in out["facets"]["vendors"]
    assert out["facets"]["on_sale"] == 1
    assert out["facets"]["price"]["min"]["currency"] == "USD"
  end

  test "an unlisted category is not named in the facets, though its product is listed" do
    unlisted = legacy_category!(%{"en" => "Hush"}, %{status: "unlisted"})
    lamp = legacy_product!(%{"en" => "Hush Lamp"}, %{category_uuid: unlisted.uuid, price: "9.00"})
    {:ok, _} = Indexer.reindex_items([lamp.uuid])

    out = search!(%{"q" => "lamp"})

    assert lamp.uuid in item_ids(out)
    refute Enum.any?(out["facets"]["categories"], &(&1["id"] == unlisted.uuid))
  end

  test "no query browses the shop", t do
    out = search!(%{})

    assert out["match_mode"] == "browse"
    assert out["count"] == 5
    assert item_ids(out) == [t.b, t.c, t.e, t.a, t.d]

    options = out["facets"]["options"]
    assert Enum.map(options, & &1["key"]) == ["colour", "size"]
    size = Enum.find(options, &(&1["key"] == "size"))

    assert size["values"] == [
             %{"key" => "large", "label" => "Large", "count" => 1},
             %{"key" => "small", "label" => "Small", "count" => 1}
           ]
  end

  test "pages follow next_cursor to the end without repeating or skipping", t do
    first = search!(%{"limit" => 2})
    assert item_ids(first) == [t.b, t.c]
    assert first["count"] == 5

    second = search!(%{"limit" => 2, "cursor" => first["next_cursor"]})
    assert item_ids(second) == [t.e, t.a]

    third = search!(%{"limit" => 2, "cursor" => second["next_cursor"]})
    assert item_ids(third) == [t.d]
    refute Map.has_key?(third, "next_cursor")
  end

  test "fields limits the keys of an item, and always keeps the id" do
    out = search!(%{"fields" => ["title", "price"]})

    for item <- out["items"] do
      assert item |> Map.keys() |> Enum.sort() == ["id", "price", "title"]
    end
  end

  test "currency override: prices and the price filter are in the response currency", t do
    out = search!(%{"currency" => "EUR", "sort" => "price_asc"})
    assert item_ids(out) == [t.d, t.c, t.e, t.a, t.b]
    a = Enum.find(out["items"], &(&1["id"] == t.a))
    assert a["price"] == %{"amount" => "18.18", "currency" => "EUR"}
    assert out["currency"] == "EUR"

    # 20.00 USD is shown as 18.18 EUR: a maximum of 18.18 includes it, 18.17 does not.
    at_edge = search!(%{"currency" => "EUR", "price_max" => "18.18"})
    assert t.a in item_ids(at_edge)
    refute t.b in item_ids(at_edge)

    below = search!(%{"currency" => "EUR", "price_max" => "18.17"})
    refute t.a in item_ids(below)
    assert below["count"] == 3
  end

  test "a bad filter is a validation error with the path of every problem" do
    assert {:error, :validation_failed, _message, %{errors: errors}} =
             Search.search_products(
               %{"category_id" => "nope", "price_min" => "5", "price_max" => "1"},
               ctx()
             )

    assert Enum.map(errors, & &1.path) |> Enum.sort() == ["category_id", "price_min"]
  end

  test "a host language 'de' finds products indexed under the dialect 'de-DE'" do
    enable_languages!(["en-US", "de-DE"])
    g = legacy_product!(%{"en-US" => "Plain Vase", "de-DE" => "Rote Vasen"})
    {:ok, _} = Indexer.reindex_items([g.uuid])

    out = search!(%{"q" => "Vase"}, language: "de")

    assert out["language"] == "de-DE"
    assert item_ids(out) == [g.uuid]
    assert hd(out["items"])["title"] == "Rote Vasen"
  end

  test "a limit above 100 is trimmed with a warning, not refused" do
    out = search!(%{"limit" => 500})

    assert [%{"code" => "limit_trimmed", "requested" => 500}] = out["warnings"]
    assert length(out["items"]) == 5
  end

  test "a tampered cursor, an unknown language and an unknown currency are validation errors" do
    assert {:error, :validation_failed, _, %{errors: [%{path: "cursor"}]}} =
             Search.search_products(%{"cursor" => "@@"}, ctx())

    assert {:error, :validation_failed, _, %{errors: [%{path: "language", allowed: ["en"]}]}} =
             Search.search_products(%{"language" => "xx"}, ctx())

    assert {:error, :validation_failed, _, %{errors: [%{path: "currency"}]}} =
             Search.search_products(%{"currency" => "XXX"}, ctx())
  end

  test "a product hidden after the index was written is never shown", t do
    {:ok, _} = Shop.update_product(Shop.get_product!(t.a), %{status: "draft"})

    # The index still holds the row (it is a few seconds behind); the card build does not.
    out = search!(%{"q" => "vase"})

    refute t.a in item_ids(out)
    assert Enum.sort(item_ids(out)) == Enum.sort([t.c, t.e])

    {:ok, _} = Indexer.reindex_items([t.a])
    assert search!(%{"q" => "vase"})["count"] == 2
  end

  test "hostile text is answered, never raised" do
    hostile =
      ["\"", "\"open", "-", "or", "the", "!!!", "a\0b", "'; DROP TABLE x; --", "😀", "%"] ++
        [String.duplicate("-", 40), String.duplicate("- ", 40) <> "a", String.duplicate("-(", 20)]

    for q <- hostile do
      assert {:ok, %{"count" => count}} = Search.search_products(%{"q" => q}, ctx())
      assert is_integer(count), inspect(q)
    end
  end

  test "the answer is plain JSON and satisfies its own output schema" do
    out = search!(%{"q" => "vase", "limit" => 2})

    assert out == out |> JSON.encode!() |> JSON.decode!()
    assert {:ok, _} = Validator.validate(Search.search_output_schema(), out)
  end

  describe "search_products_batch/2" do
    test "answers every query in order and echoes the ref", t do
      out =
        batch!(%{
          "queries" => [%{"ref" => "q1", "q" => "vase"}, %{"q" => "bowl"}, %{"q" => "zzzzqqqq"}]
        })

      assert out["count"] == 3
      assert [first, second, third] = out["results"]

      assert first["index"] == 0 and first["ref"] == "q1" and first["count"] == 3
      assert second["index"] == 1 and not Map.has_key?(second, "ref")
      assert item_ids(second) == [t.b]
      assert third["index"] == 2 and third["count"] == 0 and third["items"] == []
    end

    test "a batch builds at most its card budget: later queries are trimmed with a warning" do
      assert {:ok, out} =
               Search.search_products_batch(
                 %{"queries" => List.duplicate(%{"limit" => 5}, 3)},
                 ctx(),
                 6
               )

      assert [first, second, third] = out["results"]

      assert length(first["items"]) == 5
      refute Map.has_key?(first, "warnings")

      for block <- [second, third] do
        assert length(block["items"]) == 1
        assert [%{"code" => "batch_limit_trimmed", "applied" => 1}] = block["warnings"]
      end
    end

    test "trim_to_budget/3 trims a limit to what is left of the batch budget, never below 1" do
      assert {%{limit: 100}, []} = Search.trim_to_budget(%{limit: 100}, [], nil)
      assert {%{limit: 10}, []} = Search.trim_to_budget(%{limit: 10}, [], 30)

      assert {%{limit: 30}, [warning]} = Search.trim_to_budget(%{limit: 100}, [], 30)
      assert warning["code"] == "batch_limit_trimmed"
      assert warning["requested"] == 100 and warning["applied"] == 30

      assert {%{limit: 1}, [%{"applied" => 1}]} = Search.trim_to_budget(%{limit: 20}, [], 0)
    end

    test "one bad query is an error block and does not spoil the others" do
      out =
        batch!(%{
          "queries" => [
            %{"q" => "vase"},
            %{"ref" => "bad", "category_id" => "nope"},
            %{"q" => "bowl"}
          ]
        })

      assert [ok_a, bad, ok_b] = out["results"]
      assert ok_a["count"] == 3 and ok_b["count"] == 1

      assert %{"ref" => "bad", "error" => error} = bad
      assert error["code"] == "validation_failed"
      assert [%{"path" => "queries[1].category_id"}] = error["context"]["errors"]
      refute Map.has_key?(bad, "items")
    end

    test "currency and language apply to every query" do
      out = batch!(%{"currency" => "EUR", "queries" => [%{"q" => "spoon"}]})

      assert [%{"items" => [item], "currency" => "EUR"}] = out["results"]
      assert item["price"]["currency"] == "EUR"
    end

    test "batch_cost/1 prices a raw, unvalidated batch by its number of queries" do
      # The executor calls it BEFORE validation: it must
      # answer a positive integer for any term and never raise.
      assert Search.batch_cost(%{"queries" => List.duplicate(%{}, 7)}) == 7
      assert Search.batch_cost(%{"queries" => List.duplicate(%{}, 20)}) == 20
      assert Search.batch_cost(%{"queries" => [%{}]}) == 1
      assert Search.batch_cost(%{"queries" => []}) == 1
      # Over the cap the call is refused with 422; it is charged the cap, not 500.
      assert Search.batch_cost(%{"queries" => List.duplicate(%{}, 500)}) == 20

      for junk <- [
            %{},
            %{"queries" => "junk"},
            %{"queries" => %{"a" => 1}},
            %{"queries" => nil},
            nil,
            42,
            "x",
            []
          ] do
        assert Search.batch_cost(junk) == 1, inspect(junk)
      end
    end

    test "the batch answer is plain JSON and satisfies its output schema" do
      out = batch!(%{"queries" => [%{"q" => "vase"}, %{"category_id" => "nope"}]})

      assert out == out |> JSON.encode!() |> JSON.decode!()
      assert {:ok, _} = Validator.validate(Search.batch_output_schema(), out)
    end
  end

  test "a q over 200 characters is refused by the input schema; the handler alone truncates it" do
    long = String.duplicate("vase ", 2_000)

    assert {:error, [%{path: "q"}]} =
             Validator.validate(Search.search_input_schema(), %{"q" => long})

    assert {:ok, %{"count" => count}} = Search.search_products(%{"q" => long}, ctx())
    assert is_integer(count)
  end

  test "the input schemas accept what the handlers read and close the object" do
    assert {:ok, _} =
             Validator.validate(Search.search_input_schema(), %{
               "q" => "vase",
               "limit" => 5,
               "options" => %{"size" => ["large"]},
               "price_min" => 1,
               "price_max" => "20.50",
               "fields" => ["title"],
               "language" => "en",
               "currency" => "USD"
             })

    assert {:error, [%{path: "limit"}]} =
             Validator.validate(Search.search_input_schema(), %{"limit" => 0})

    assert {:error, [%{path: "fields[0]"}]} =
             Validator.validate(Search.search_input_schema(), %{
               "fields" => ["cost_per_item"]
             })

    queries = List.duplicate(%{}, 21)

    assert {:error, [%{path: "queries"}]} =
             Validator.validate(Search.batch_input_schema(), %{
               "queries" => queries
             })
  end
end
