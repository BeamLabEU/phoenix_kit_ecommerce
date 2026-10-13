defmodule PhoenixKitEcommerce.Search.Indexer do
  @moduledoc """
  Writes the public search index (`phoenix_kit_shop_search_index`).

  Every run stamps the rows it writes with one `indexed_at` (the moment the
  run started), **upserts first**, and then deletes the rows of its scope
  that carry an older stamp. A product that stopped being listed, a deleted
  product and a language that was switched off are all "rows nobody touched
  in this run", so one rule removes them. Because the primary key of a row
  survives an upsert, a search that runs during a rebuild still finds every
  product that stays listed.

    * `reindex_items/1` - the given product ids (an item edit, a bulk change).
    * `rebuild/0` - the whole shop (the nightly safety net). If the shop's
      catalogue cannot be resolved it returns `{:error, :no_catalogue}` and
      deletes nothing: an unresolvable catalogue is not an empty shop.

  Rows are written with raw SQL because the `document` column is a
  `tsvector` that Postgres builds with the language's configuration
  (`PhoenixKitEcommerce.Search.Dictionary`) from the weighted parts of
  `PhoenixKitEcommerce.Search.Document`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.Search.Document
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Trigram
  alias PhoenixKitEcommerce.Translations

  @chunk 100
  @delete_chunk 500

  @doc """
  Re-indexes `uuids`: listed products are upserted in every enabled language,
  every other row of these products is removed.

  Like `rebuild/0` it changes nothing while the Catalogue source is on and the
  shop's catalogue cannot be resolved: the loader would answer an empty map and
  `delete_stale/2` would then remove the rows of every id it was given.
  """
  @spec reindex_items([term()]) ::
          {:ok, %{indexed: non_neg_integer(), removed: non_neg_integer()}}
  def reindex_items(uuids) when is_list(uuids) do
    if Loader.source_resolvable?() do
      uuids = uuids |> Enum.filter(&(is_binary(&1) and UUIDUtils.valid?(&1))) |> Enum.uniq()
      started = DateTime.utc_now()
      indexed = index_all(uuids, started)
      removed = delete_stale(uuids, started)
      {:ok, %{indexed: indexed, removed: removed}}
    else
      Logger.warning("[Search] reindex skipped: the shop catalogue cannot be resolved")
      {:ok, %{indexed: 0, removed: 0}}
    end
  end

  @doc "Rebuilds the whole index from the product source."
  @spec rebuild() ::
          {:ok,
           %{products: non_neg_integer(), indexed: non_neg_integer(), removed: non_neg_integer()}}
          | {:error, :no_catalogue}
  def rebuild do
    case Loader.all_ids() do
      {:error, :no_catalogue} = error ->
        Logger.warning("[Search] rebuild skipped: the shop catalogue cannot be resolved")
        error

      {:ok, ids} ->
        started = DateTime.utc_now()
        indexed = index_all(ids, started)

        {removed, _} =
          RepoHelper.repo().delete_all(from(e in Entry, where: e.indexed_at < ^started))

        Logger.info(
          "[Search] rebuild: #{length(ids)} products, #{indexed} rows written, #{removed} removed"
        )

        {:ok, %{products: length(ids), indexed: indexed, removed: removed}}
    end
  end

  @doc "Row counts per language, and whether the typo fallback is available."
  @spec status() :: %{
          rows: non_neg_integer(),
          languages: %{String.t() => non_neg_integer()},
          trigram: boolean()
        }
  def status do
    languages =
      from(e in Entry, group_by: e.language, select: {e.language, count(e.uuid)})
      |> RepoHelper.repo().all()
      |> Map.new()

    %{
      rows: languages |> Map.values() |> Enum.sum(),
      languages: languages,
      trigram: Trigram.available?()
    }
  end

  @doc "True when the index has no row at all."
  @spec empty?() :: boolean()
  def empty?, do: not RepoHelper.repo().exists?(Entry)

  # --- writing ---------------------------------------------------------------

  defp index_all([], _started), do: 0

  defp index_all(ids, started) do
    languages = Translations.enabled_languages()
    categories = Loader.categories()

    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn chunk, total ->
      total + index_chunk(chunk, started, languages, categories)
    end)
  end

  # Split into three small functions: Credo (`--strict`) refuses a function
  # body nested deeper than two levels.
  defp index_chunk(chunk, started, languages, categories) do
    rows = Enum.flat_map(languages, &language_rows(chunk, &1, categories))

    repo = RepoHelper.repo()

    {:ok, _} =
      repo.transaction(fn -> Enum.each(rows, &upsert(repo, &1, started)) end, timeout: :infinity)

    length(rows)
  end

  defp language_rows(chunk, language, categories) do
    chunk
    |> Loader.load(language: language, categories: categories)
    |> Map.values()
    |> Enum.filter(&(&1.state == :listed))
    |> Enum.flat_map(&document_rows(&1, language))
  end

  defp document_rows(%Record{} = record, language) do
    case Document.build(record, language) do
      nil -> []
      row -> [row]
    end
  end

  defp delete_stale(uuids, started) do
    uuids
    |> Enum.chunk_every(@delete_chunk)
    |> Enum.reduce(0, fn chunk, total ->
      {count, _} =
        RepoHelper.repo().delete_all(
          from(e in Entry, where: e.item_uuid in ^chunk and e.indexed_at < ^started)
        )

      total + count
    end)
  end

  defp upsert(repo, row, started) do
    repo.query!(upsert_sql(), [
      dump_uuid(row.item_uuid),
      row.language,
      row.title,
      row.regconfig,
      row.text_b,
      row.text_c,
      row.text_d,
      dump_uuid(row.category_uuid),
      row.category_path,
      Enum.map(row.category_path_uuids, &dump_uuid/1),
      row.vendor,
      row.tags,
      row.option_pairs,
      row.option_labels,
      row.made_to_order,
      row.on_sale,
      row.price,
      row.compare_at_price,
      row.discount_pct,
      row.sort_position,
      row.item_inserted_at,
      started
    ])
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  defp upsert_sql do
    """
    INSERT INTO #{Entry.table()}
      (item_uuid, language, title, title_trgm, document, category_uuid, category_path,
       category_path_uuids, vendor, tags, option_pairs, option_labels, made_to_order, on_sale,
       price, compare_at_price, discount_pct, sort_position, item_inserted_at, indexed_at)
    VALUES
      ($1::uuid, $2::text, $3::text, lower($3::text),
       setweight(to_tsvector($4::text::regconfig, $3::text), 'A') ||
       setweight(to_tsvector($4::text::regconfig, $5::text), 'B') ||
       setweight(to_tsvector($4::text::regconfig, $6::text), 'C') ||
       setweight(to_tsvector($4::text::regconfig, $7::text), 'D'),
       $8::uuid, $9::text[], $10::uuid[], $11::text, $12::text[], $13::text[], $14::jsonb,
       $15::boolean, $16::boolean, $17::numeric, $18::numeric, $19::numeric, $20::integer,
       $21::timestamptz, $22::timestamptz)
    ON CONFLICT (item_uuid, language) DO UPDATE SET
      title = EXCLUDED.title,
      title_trgm = EXCLUDED.title_trgm,
      document = EXCLUDED.document,
      category_uuid = EXCLUDED.category_uuid,
      category_path = EXCLUDED.category_path,
      category_path_uuids = EXCLUDED.category_path_uuids,
      vendor = EXCLUDED.vendor,
      tags = EXCLUDED.tags,
      option_pairs = EXCLUDED.option_pairs,
      option_labels = EXCLUDED.option_labels,
      made_to_order = EXCLUDED.made_to_order,
      on_sale = EXCLUDED.on_sale,
      price = EXCLUDED.price,
      compare_at_price = EXCLUDED.compare_at_price,
      discount_pct = EXCLUDED.discount_pct,
      sort_position = EXCLUDED.sort_position,
      item_inserted_at = EXCLUDED.item_inserted_at,
      indexed_at = EXCLUDED.indexed_at
    """
  end
end
