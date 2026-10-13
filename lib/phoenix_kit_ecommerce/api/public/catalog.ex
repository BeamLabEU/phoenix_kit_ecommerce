defmodule PhoenixKitEcommerce.API.Public.Catalog do
  @moduledoc """
  Handlers and schemas of `shop.get_products`, `shop.list_categories` and
  `shop.similar_products`.

  What a caller may see of a product is decided in one place,
  `PhoenixKitEcommerce.API.Visibility`, and all three tools go
  through it: a hidden product, a malformed id and an unknown id produce the
  same `not_found`, so an answer never tells a caller that a hidden product
  exists.
  """

  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Cards
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Public.Schemas
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Translations

  @max_ids 50
  @default_similar 10
  @max_similar 20
  @not_found %{"code" => "not_found", "message" => "No such product."}

  # --- shop.get_products -----------------------------------------------------

  @spec get_products(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def get_products(%{"ids" => ids} = input, ctx) when is_list(ids) do
    with {:ok, context} <- Context.build(input, ctx) do
      format = Map.get(input, "format", "text")

      Context.with_request_currency(context, fn ->
        {:ok, products_answer(ids, format, context)}
      end)
    end
  end

  defp products_answer(ids, format, context) do
    canonical = Enum.map(ids, &canonical_id/1)
    records = canonical |> Enum.reject(&is_nil/1) |> Loader.load(language: context.language)

    results =
      ids
      |> Enum.zip(canonical)
      |> Enum.map(fn {ref, id} -> row(ref, id && Map.get(records, id), context, format) end)

    %{"results" => results, "summary" => summary(results)}
  end

  defp row(ref, %Record{state: :listed} = record, context, format),
    do: %{"ref" => ref, "product" => Cards.card(record, context, format: format)}

  defp row(ref, %Record{state: :discontinued} = record, context, _format),
    do: %{"ref" => ref, "product" => Cards.stub(record, context)}

  defp row(ref, _hidden_or_unknown, _context, _format), do: %{"ref" => ref, "error" => @not_found}

  defp summary(results) do
    %{
      "found" => Enum.count(results, &(get_in(&1, ["product", "status"]) == "active")),
      "discontinued" =>
        Enum.count(results, &(get_in(&1, ["product", "status"]) == "discontinued")),
      "not_found" => Enum.count(results, &Map.has_key?(&1, "error"))
    }
  end

  # A 36-character UUID in any letter case; anything else (a 16-byte string
  # that `Ecto.UUID.cast/1` would take for a raw UUID included) is no id.
  defp canonical_id(id) when is_binary(id) do
    if UUIDUtils.valid?(id), do: String.downcase(id)
  end

  defp canonical_id(_other), do: nil

  # --- shop.list_categories --------------------------------------------------

  @spec list_categories(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def list_categories(input, ctx) do
    with {:ok, context} <- Context.build(input, ctx) do
      Context.with_request_currency(context, fn -> {:ok, categories_answer(context)} end)
    end
  end

  defp categories_answer(context) do
    categories =
      Loader.categories()
      |> Map.values()
      |> Enum.filter(&(&1.status == "active"))

    counts = Query.category_counts(context.language)

    %{"categories" => tree(categories, counts, context), "count" => length(categories)}
  end

  defp tree(categories, counts, context) do
    by_parent = Enum.group_by(categories, & &1.parent_uuid)
    known = MapSet.new(categories, & &1.uuid)

    categories
    |> Enum.filter(&(is_nil(&1.parent_uuid) or not MapSet.member?(known, &1.parent_uuid)))
    |> sort(context)
    |> Enum.map(&category_node(&1, by_parent, counts, context, MapSet.new([&1.uuid])))
  end

  defp category_node(category, by_parent, counts, context, seen) do
    children =
      by_parent
      |> Map.get(category.uuid, [])
      |> Enum.reject(&MapSet.member?(seen, &1.uuid))
      |> sort(context)
      |> Enum.map(&category_node(&1, by_parent, counts, context, MapSet.put(seen, &1.uuid)))

    own = Map.get(counts, category.uuid, 0)
    language = context.language

    %{
      "id" => category.uuid,
      "name" => Translations.get_display(category, :name, language) || "",
      "slug" => Translations.get_slug(category, language),
      "url" => Context.absolute(context, Shop.category_url(category, language)),
      "product_count" => own,
      "total_count" => own + Enum.sum(Enum.map(children, & &1["total_count"])),
      "children" => children
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp sort(categories, context) do
    Enum.sort_by(
      categories,
      &{&1.position || 0, Translations.get_display(&1, :name, context.language) || ""}
    )
  end

  # --- shop.similar_products -------------------------------------------------

  @spec similar_products(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def similar_products(%{"id" => id} = input, ctx) do
    with {:ok, context} <- Context.build(input, ctx),
         {:ok, base} <- listed_entry(id, context) do
      {limit, warnings} = similar_limit(Map.get(input, "limit"))

      Context.with_request_currency(context, fn ->
        {:ok, similar_answer(base, limit, warnings, context)}
      end)
    end
  end

  defp similar_answer(base, limit, warnings, context) do
    ids = Query.similar(base, limit)
    records = Loader.load(ids, language: context.language)

    items =
      for id <- ids, %Record{state: :listed} = record <- [Map.get(records, id)] do
        Cards.list_item(record, context)
      end

    out = %{"items" => items, "count" => length(items)}
    if warnings == [], do: out, else: Map.put(out, "warnings", warnings)
  end

  # The base product must be listed now (a live check) and indexed, else not_found.
  defp listed_entry(id, context) do
    with uuid when is_binary(uuid) <- canonical_id(id),
         %{} = entry <- Query.entry(uuid, context.language),
         %Record{state: :listed} <- Map.get(Loader.load([uuid], language: context.language), uuid) do
      {:ok, entry}
    else
      _none -> {:error, :not_found, "No such product.", %{}}
    end
  end

  defp similar_limit(nil), do: {@default_similar, []}

  defp similar_limit(n) when is_integer(n) and n > @max_similar do
    {@max_similar,
     [
       %{
         "code" => "limit_trimmed",
         "message" => "limit was reduced to #{@max_similar}",
         "requested" => n,
         "applied" => @max_similar
       }
     ]}
  end

  defp similar_limit(n) when is_integer(n) and n >= 1, do: {n, []}
  defp similar_limit(_other), do: {@default_similar, []}

  # --- schemas ---------------------------------------------------------------

  @spec get_products_input_schema() :: map()
  def get_products_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["ids"],
      "properties" =>
        Map.merge(
          %{
            "ids" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_ids,
              "items" => %{"type" => "string", "maxLength" => 64},
              "description" => "Product ids, as returned by search (at most #{@max_ids})."
            },
            "format" => %{
              "type" => "string",
              "enum" => ["text", "markdown"],
              "description" => "How to write the description: plain text (default) or Markdown."
            }
          },
          Schemas.control_fields()
        )
    }
  end

  @spec get_products_output_schema() :: map()
  def get_products_output_schema do
    %{
      "type" => "object",
      "required" => ["results", "summary"],
      "properties" => %{
        "results" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["ref"],
            "properties" => %{
              "ref" => %{"type" => "string"},
              "product" => Schemas.card(),
              "error" => %{
                "type" => "object",
                "required" => ["code", "message"],
                "properties" => %{
                  "code" => %{"type" => "string"},
                  "message" => %{"type" => "string"}
                }
              }
            }
          }
        },
        "summary" => %{
          "type" => "object",
          "properties" => %{
            "found" => %{"type" => "integer"},
            "discontinued" => %{"type" => "integer"},
            "not_found" => %{"type" => "integer"}
          }
        }
      }
    }
  end

  @spec list_categories_input_schema() :: map()
  def list_categories_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => Schemas.control_fields()
    }
  end

  @spec list_categories_output_schema() :: map()
  def list_categories_output_schema do
    node = %{
      "type" => "object",
      "required" => ["id", "name", "product_count", "total_count", "children"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "name" => %{"type" => "string"},
        "slug" => %{"type" => "string"},
        "url" => %{"type" => "string"},
        "product_count" => %{"type" => "integer"},
        "total_count" => %{"type" => "integer"},
        "children" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    }

    %{
      "type" => "object",
      "required" => ["categories", "count"],
      "properties" => %{
        "categories" => %{"type" => "array", "items" => node},
        "count" => %{"type" => "integer"}
      }
    }
  end

  @spec similar_products_input_schema() :: map()
  def similar_products_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id"],
      "properties" =>
        Map.merge(
          %{
            "id" => %{"type" => "string", "maxLength" => 64, "description" => "A product id."},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 1_000_000,
              "description" =>
                "How many products. Default #{@default_similar}; above #{@max_similar} is reduced with a warning."
            }
          },
          Schemas.control_fields()
        )
    }
  end

  @spec similar_products_output_schema() :: map()
  def similar_products_output_schema do
    %{
      "type" => "object",
      "required" => ["items", "count"],
      "properties" => %{
        "items" => %{"type" => "array", "items" => Schemas.list_item()},
        "count" => %{"type" => "integer"},
        "warnings" => Schemas.warnings()
      }
    }
  end
end
