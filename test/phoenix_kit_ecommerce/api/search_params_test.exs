defmodule PhoenixKitEcommerce.API.SearchParamsTest do
  @moduledoc """
  Turns one search query (decoded JSON) into the params of `Search.Query`.
  Pure: contexts are built by hand, no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.SearchParams
  alias PhoenixKitEcommerce.Search.Query

  defp currency(code, rate),
    do: struct(Currency, code: code, decimal_places: 2, exchange_rate: Decimal.new(rate))

  defp context(code \\ "USD") do
    base = currency("USD", "1.0")
    shown = if code == "USD", do: base, else: currency(code, "0.909091")

    %Context{
      language: "en",
      default_language: "en",
      currency: shown,
      base: base,
      base_url: "https://shop.test"
    }
  end

  defp ok(query, ctx \\ context()) do
    assert {:ok, params, warnings} = SearchParams.normalize(query, ctx)
    {params, warnings}
  end

  defp errors(query, ctx \\ context(), prefix \\ "") do
    assert {:error, errors} = SearchParams.normalize(query, ctx, prefix)
    errors
  end

  test "an empty query is the first page of everything" do
    {params, warnings} = ok(%{})

    # No `options` key: put_options/2 leaves the state alone for a missing field,
    # and Search.Query.run/2 merges its own defaults (`options: %{}`).
    assert params == %{q: nil, limit: 20, offset: 0, sort: :relevance}
    assert warnings == []
  end

  test "q is cleaned like the query module cleans it" do
    assert {%{q: "vase"}, []} = ok(%{"q" => "  vase  "})
    assert {%{q: nil}, []} = ok(%{"q" => "   "})
    assert {%{q: "ab"}, []} = ok(%{"q" => "a\0b"})
    assert {%{q: nil}, []} = ok(%{"q" => 42})
    assert Query.clean_q("  vase  ") == "vase"
  end

  test "category_id must be a UUID and is stored in its canonical form" do
    id = Ecto.UUID.generate()

    assert {%{category_id: ^id}, []} = ok(%{"category_id" => String.upcase(id)})
    assert [%{path: "category_id"}] = errors(%{"category_id" => "not-a-uuid"})
    assert [%{path: "category_id"}] = errors(%{"category_id" => 7})
  end

  test "prices accept numbers and decimal strings and refuse the rest" do
    assert {%{price_min: min, price_max: max}, []} =
             ok(%{"price_min" => 5, "price_max" => "12.50"})

    assert Decimal.equal?(min, Decimal.new("5"))
    assert Decimal.equal?(max, Decimal.new("12.50"))

    assert {%{price_min: float}, []} = ok(%{"price_min" => 2.5})
    assert Decimal.equal?(float, Decimal.new("2.5"))

    for bad <- [-1, "-1", "abc", "NaN", "Infinity", "", true, %{}] do
      assert [%{path: "price_min"}] = errors(%{"price_min" => bad}), inspect(bad)
    end
  end

  test "a minimum above the maximum is one error on price_min" do
    assert [%{path: "price_min", message: message}] =
             errors(%{"price_min" => 10, "price_max" => 5})

    assert message =~ "price_max"
  end

  test "bounds in another currency are converted to the base currency and widened by half a cent" do
    eur = context("EUR")
    # 20.00 USD is shown as 18.18 EUR.
    twenty = Decimal.new("20")

    assert {%{price_max: at_edge}, []} = ok(%{"price_max" => "18.18"}, eur)
    assert Decimal.compare(at_edge, twenty) == :gt

    assert {%{price_max: below}, []} = ok(%{"price_max" => "18.17"}, eur)
    assert Decimal.compare(below, twenty) == :lt

    assert {%{price_min: min_edge}, []} = ok(%{"price_min" => "18.18"}, eur)
    assert Decimal.compare(min_edge, twenty) == :lt

    assert {%{price_min: min_above}, []} = ok(%{"price_min" => "18.19"}, eur)
    assert Decimal.compare(min_above, twenty) == :gt

    assert {%{price_min: zero}, []} = ok(%{"price_min" => "0"}, eur)
    assert Decimal.compare(zero, 0) == :eq
  end

  test "options keep values unique and refuse malformed shapes" do
    assert {%{options: %{"size" => ["large", "xl"]}}, []} =
             ok(%{"options" => %{"size" => ["large", "xl", "large"]}})

    for bad <- [
          "size:large",
          %{"size" => "large"},
          %{"size" => []},
          %{"size" => [1]},
          %{"size" => [""]},
          %{"a:b" => ["x"]},
          %{"" => ["x"]},
          %{"size" => Enum.map(1..51, &"v#{&1}")},
          Map.new(1..21, &{"k#{&1}", ["x"]})
        ] do
      assert [%{path: "options" <> _}] = errors(%{"options" => bad}), inspect(bad, limit: 5)
    end
  end

  test "vendor, on_sale and made_to_order" do
    assert {%{vendor: "Acme"}, []} = ok(%{"vendor" => " Acme "})
    assert {params, []} = ok(%{"vendor" => "  "})
    refute Map.has_key?(params, :vendor)
    assert [%{path: "vendor"}] = errors(%{"vendor" => String.duplicate("a", 201)})
    # The limit counts characters, as the tool schema does, not bytes.
    assert {%{vendor: _}, []} = ok(%{"vendor" => String.duplicate("é", 150)})

    assert {%{on_sale: true, made_to_order: false}, []} =
             ok(%{"on_sale" => true, "made_to_order" => false})

    assert [%{path: "on_sale"}, %{path: "made_to_order"}] =
             errors(%{"on_sale" => "yes", "made_to_order" => 1})
  end

  test "sort maps to an atom and refuses anything else with the allowed list" do
    assert {%{sort: :price_desc}, []} = ok(%{"sort" => "price_desc"})
    assert {%{sort: :relevance}, []} = ok(%{})

    assert [%{path: "sort", allowed: allowed}] = errors(%{"sort" => "random"})
    assert Enum.sort(allowed) == ~w(discount_desc newest price_asc price_desc relevance)
  end

  test "limit defaults to 20, is trimmed above 100 with a warning, and refuses anything below 1" do
    assert {%{limit: 20}, []} = ok(%{})
    assert {%{limit: 50}, []} = ok(%{"limit" => 50})
    assert {%{limit: 100}, []} = ok(%{"limit" => 100})

    assert {%{limit: 100}, [warning]} = ok(%{"limit" => 500})
    assert warning["code"] == "limit_trimmed"
    assert warning["requested"] == 500

    for bad <- [0, -3, "5", 2.5, true] do
      assert [%{path: "limit"}] = errors(%{"limit" => bad}), inspect(bad)
    end
  end

  test "cursor becomes an offset; a tampered cursor is an error" do
    assert {%{offset: 0}, []} = ok(%{})
    assert {%{offset: 40}, []} = ok(%{"cursor" => Query.encode_cursor(40)})
    assert [%{path: "cursor"}] = errors(%{"cursor" => "@@@"})
    assert [%{path: "cursor"}] = errors(%{"cursor" => Base.url_encode64("o:-1", padding: false)})
  end

  test "errors carry the path prefix of a batch query, and all of them are reported together" do
    errors =
      errors(%{"category_id" => "x", "sort" => "random", "limit" => 0}, context(), "queries[3].")

    assert Enum.map(errors, & &1.path) |> Enum.sort() ==
             ["queries[3].category_id", "queries[3].limit", "queries[3].sort"]
  end
end
