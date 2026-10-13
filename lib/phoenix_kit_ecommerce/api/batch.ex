defmodule PhoenixKitEcommerce.API.Batch do
  @moduledoc """
  The steps every batch write tool shares: resolve the references, plan each
  row, write the rows that change, and shape the answer (spec 5.4).

  A row is a map:

      %{index: 0, input: %{...}, ref: %{"sku" => "A"}, item: item | nil,
        plan: plan | nil, error: row_error | nil, result: nil | {:ok, item} | {:error, row_error},
        extra: %{}}

  A plan is whatever the tool's planner returns, with at least `:from`
  (the current values of the fields the row touches), `:changes`
  (`field => %{"from" => _, "to" => _}`), `:changed?`, `:dangerous?`,
  `:warnings`, `:attrs` and `:owned_paths`.
  """

  alias PhoenixKitEcommerce.API.{CatalogueWrites, Fingerprint, Meta, Refs, Rows}
  alias PhoenixKitEcommerce.StorefrontCache

  @type row :: %{
          index: non_neg_integer(),
          input: map(),
          ref: term(),
          item: struct() | nil,
          plan: map() | nil,
          error: Rows.t() | nil,
          result: nil | {:ok, struct()} | {:unchanged, struct()} | {:error, Rows.t()},
          extra: map()
        }

  @doc "Resolves the `\"ref\"` of every item. A product named twice fails from its second row on."
  @spec load([map()], String.t()) :: [row()]
  def load(items, catalogue_uuid) when is_list(items) do
    refs = Enum.map(items, &Map.get(&1, "ref"))

    items
    |> Enum.zip(Refs.resolve(refs, catalogue_uuid))
    |> Enum.with_index()
    |> Enum.map(fn {{input, answer}, index} -> row(index, input, answer) end)
    |> mark_duplicates()
  end

  defp row(index, input, {:ok, item}),
    do: %{
      index: index,
      input: input,
      ref: input["ref"],
      item: item,
      plan: nil,
      error: nil,
      result: nil,
      extra: %{}
    }

  defp row(index, input, {:error, error}),
    do: %{
      index: index,
      input: input,
      ref: input["ref"],
      item: nil,
      plan: nil,
      error: error,
      result: nil,
      extra: %{}
    }

  defp mark_duplicates(rows) do
    {rows, _seen} =
      Enum.map_reduce(rows, %{}, fn
        %{item: nil} = row, seen ->
          {row, seen}

        %{item: item} = row, seen ->
          case Map.fetch(seen, item.uuid) do
            {:ok, first} ->
              error =
                Rows.error(
                  :duplicate_line,
                  "This product is already given in items[#{first}].",
                  %{
                    "first_index" => first
                  }
                )

              {fail(row, error), seen}

            :error ->
              {row, Map.put(seen, item.uuid, row.index)}
          end
      end)

    rows
  end

  @doc "Marks a row as failed."
  @spec fail(row(), Rows.t()) :: row()
  def fail(row, error), do: %{row | error: error, plan: nil}

  @doc """
  Plans every row that resolved. `planner` takes the row and returns
  `{:ok, plan}` or `{:error, row_error}`.
  """
  @spec plan([row()], (row() -> {:ok, map()} | {:error, Rows.t()})) :: [row()]
  def plan(rows, planner) do
    Enum.map(rows, fn
      %{error: nil} = row ->
        case planner.(row) do
          {:ok, plan} -> %{row | plan: plan}
          {:error, error} -> fail(row, error)
        end

      row ->
        row
    end)
  end

  @doc """
  Whether any planned row is dangerous by its own value (a price moving past
  the threshold). The size of the batch is not asked here: core's executor
  holds every admin write tool whose longest list passes `api_confirm_batch_over`.
  """
  @spec dangerous?([row()]) :: boolean()
  def dangerous?(rows) do
    Enum.any?(rows, fn
      %{plan: %{dangerous?: true}} -> true
      _row -> false
    end)
  end

  @doc "The value fingerprint of the rows that were planned."
  @spec fingerprint([row()]) :: String.t()
  def fingerprint(rows) do
    Fingerprint.compute(for %{item: item, plan: %{from: from}} <- rows, do: {item.uuid, from})
  end

  @doc """
  Writes every row whose plan changes something, in one catalogue batch, and
  records the result on the row. Each row owns exactly the `data` paths its
  plan lists (`row_opts`), so a row that does not touch a path keeps the fresh
  value of it, and a price-only row owns no path at all. `mode: "auto"` marks
  the log entries as not made by hand; `skip_derive: true` because no tool
  here moves a product between categories.
  """
  @spec write([row()], map(), String.t()) :: [row()]
  def write(rows, ctx, tool) do
    pending = for %{plan: %{changed?: true}} = row <- rows, do: row

    entries =
      Enum.map(pending, fn row ->
        paths = row.plan.owned_paths
        {row.item, row.plan.attrs, data_owned_paths: paths, logged_data_paths: paths}
      end)

    opts = [
      actor_uuid: Meta.actor_uuid(ctx),
      log_metadata: Meta.log_metadata(ctx, tool),
      mode: "auto",
      skip_derive: true
    ]

    results =
      pending
      |> Enum.map(& &1.index)
      |> Enum.zip(CatalogueWrites.update_rows(entries, opts))
      |> Map.new()

    clear_storefront_cache(results)

    Enum.map(rows, fn row ->
      case Map.fetch(results, row.index) do
        {:ok, {:ok, item}} -> %{row | item: item, result: {:ok, item}}
        {:ok, {:unchanged, item}} -> %{row | item: item, result: {:unchanged, item}}
        {:ok, {:error, error}} -> %{row | result: {:error, error}}
        :error -> row
      end
    end)
  end

  # The storefront caches its category list and facets for about a minute
  # (`StorefrontCache`); a write of this package must show on the next page
  # view, as the Shopify sync's catalogue writes do. Only a row that changed.
  defp clear_storefront_cache(results) do
    if Enum.any?(results, &match?({_index, {:ok, _item}}, &1)), do: StorefrontCache.clear()
    :ok
  end

  @doc "The `results` list and the `summary` of a finished batch."
  @spec render([row()]) :: map()
  def render(rows) do
    results = Enum.map(rows, &result/1)
    %{"results" => results, "summary" => Enum.frequencies_by(results, & &1["action"])}
  end

  defp result(%{error: error} = row) when not is_nil(error),
    do: %{"ref" => row.ref, "action" => "error", "error" => error}

  defp result(%{result: {:error, error}} = row),
    do: %{"ref" => row.ref, "action" => "error", "error" => error}

  defp result(%{result: {:unchanged, item}, plan: plan} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "unchanged",
        "id" => item.uuid,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  defp result(%{result: {:ok, item}, plan: plan} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "updated",
        "id" => item.uuid,
        "changes" => plan.changes,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  defp result(%{plan: plan, item: item} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "unchanged",
        "id" => item.uuid,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  @doc "The preview of a dry run: what each row would do, and the totals."
  @spec preview([row()], map()) :: map()
  def preview(rows, extra_totals \\ %{}) do
    preview_rows = Enum.map(rows, &preview_row/1)
    counts = Enum.frequencies_by(preview_rows, & &1["action"])

    totals =
      %{
        "rows" => length(rows),
        "update" => Map.get(counts, "update", 0),
        "unchanged" => Map.get(counts, "unchanged", 0),
        "error" => Map.get(counts, "error", 0)
      }
      |> Map.merge(extra_totals)

    %{"rows" => preview_rows, "totals" => totals}
  end

  defp preview_row(%{error: error} = row) when not is_nil(error),
    do: %{"ref" => row.ref, "action" => "error", "error" => error}

  defp preview_row(%{plan: %{changed?: true} = plan, item: item} = row) do
    %{
      "ref" => row.ref,
      "action" => "update",
      "id" => item.uuid,
      "changes" => plan.changes,
      "warnings" => plan.warnings
    }
  end

  defp preview_row(%{plan: plan, item: item} = row),
    do: %{
      "ref" => row.ref,
      "action" => "unchanged",
      "id" => item.uuid,
      "warnings" => plan.warnings
    }
end
