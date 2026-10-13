defmodule PhoenixKitEcommerce.Search.Query do
  @moduledoc """
  Reads the public search index (`phoenix_kit_shop_search_index`).

  `run/2` answers one search: it filters the rows of one language, matches the
  query text, orders, pages, and folds facets over the matched set. It returns
  product ids only; the cards are built from live data by the tools, which also
  re-check visibility, so a stale row can never show a hidden product.

  ## Matching

    1. No query: `:browse`, ordered by the catalogue position, then the title.
    2. `websearch_to_tsquery(<language configuration>, q)` against `document`,
       ranked with `ts_rank_cd`: `:fulltext`. It accepts any text. Unbalanced
       quotes, operators and stop words only loosen or empty the query.
    3. Only when step 2 finds nothing and the `pg_trgm` extension is installed:
       `title_trgm %> q` (word similarity of at least 0.45, set with
       `set_config` for the transaction the typo path runs in), best first:
       `:typo`.

  ## Cursors

  A cursor is an opaque offset (`base64url("o:<n>")`, at most 10 000). The
  relevance rank is a float, which makes a keyset cursor fragile; the shop's
  catalogue is hundreds to low thousands of products, and `count` is exact
  either way.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitEcommerce.Search.Dictionary
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Trigram

  @facet_cap 5_000
  @typo_threshold 0.45
  @max_offset 10_000
  @max_q_length 200

  @defaults %{
    q: nil,
    category_id: nil,
    price_min: nil,
    price_max: nil,
    options: %{},
    vendor: nil,
    on_sale: nil,
    made_to_order: nil,
    sort: :relevance,
    limit: 20,
    offset: 0
  }

  @type params :: map()

  @type result :: %{
          ids: [String.t()],
          count: non_neg_integer(),
          mode: :browse | :fulltext | :typo,
          facets: map(),
          truncated?: boolean()
        }

  @doc "Runs one search in `language`. See the moduledoc for `params`."
  @spec run(params(), String.t()) :: result()
  def run(params, language) when is_map(params) and is_binary(language) do
    params = @defaults |> Map.merge(params) |> Map.update!(:q, &clean_q/1)
    {matched, mode} = language |> filtered(params) |> match(params, language)

    if mode == :typo,
      do: in_typo_transaction(fn -> read(matched, mode, params, language) end),
      else: read(matched, mode, params, language)
  end

  defp read(matched, mode, params, language) do
    count = RepoHelper.repo().aggregate(matched, :count)

    ids =
      matched
      |> ordered(mode, params, language)
      |> limit(^params.limit)
      |> offset(^params.offset)
      |> select([e], e.item_uuid)
      |> RepoHelper.repo().all()

    facets = facets(matched)

    %{ids: ids, count: count, mode: mode, facets: facets, truncated?: count > @facet_cap}
  end

  # The `%>` operator reads the threshold from the session setting
  # `pg_trgm.word_similarity_threshold` (default 0.6). `SET LOCAL` needs one
  # transaction around the count, the page and the facets, so the typo path
  # runs in one and the setting dies with it. Verified with psql:
  # `select set_config('pg_trgm.word_similarity_threshold', '0.45', true)`.
  defp in_typo_transaction(fun) do
    repo = RepoHelper.repo()

    {:ok, result} =
      repo.transaction(fn ->
        repo.query!("SELECT set_config('pg_trgm.word_similarity_threshold', $1, true)", [
          Float.to_string(@typo_threshold)
        ])

        fun.()
      end)

    result
  end

  @doc """
  The query text as the index will see it: NUL bytes removed (Postgres refuses
  them in text), a `-` that is not directly followed by a letter or digit
  turned into a space (a run of 33 or more nested negations makes
  `websearch_to_tsquery` raise `tsquery stack too small`; `-vase` and `co-op`
  keep their meaning), trimmed, at most #{@max_q_length} characters; blank or
  not a string is `nil` (no query).
  """
  @spec clean_q(term()) :: String.t() | nil
  def clean_q(q) when is_binary(q) do
    cleaned =
      q
      |> String.replace(<<0>>, "")
      |> String.slice(0, @max_q_length)
      |> then(&Regex.replace(~r/-(?![\p{L}\p{N}])/u, &1, " "))
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  def clean_q(_other), do: nil

  @doc "The number of products listed directly in each category, in one language: `%{category_uuid => n}`."
  @spec category_counts(String.t()) :: %{String.t() => non_neg_integer()}
  def category_counts(language) when is_binary(language) do
    from(e in Entry,
      where: e.language == ^language and not is_nil(e.category_uuid),
      group_by: e.category_uuid,
      select: {e.category_uuid, count(e.uuid)}
    )
    |> RepoHelper.repo().all()
    |> Map.new()
  end

  @doc "The index row of one product in one language, or `nil`. `item_uuid` must be a valid UUID."
  @spec entry(String.t(), String.t()) :: Entry.t() | nil
  def entry(item_uuid, language) when is_binary(item_uuid) and is_binary(language) do
    RepoHelper.repo().one(
      from(e in Entry, where: e.item_uuid == ^item_uuid and e.language == ^language)
    )
  end

  @doc """
  Product ids similar to `base`, best first: the same category, then the most
  shared option values and tags, then a price within +-50%, then the newest. A
  product must share its category, an option value or a tag to qualify.
  """
  @spec similar(Entry.t(), pos_integer()) :: [String.t()]
  def similar(%Entry{} = base, limit) when is_integer(limit) and limit > 0 do
    pairs = base.option_pairs
    tags = base.tags
    category = base.category_uuid
    price = base.price

    from(e in Entry,
      where: e.language == ^base.language and e.item_uuid != ^base.item_uuid,
      where:
        fragment(
          "(? = ? OR ? && ?::text[] OR ? && ?::text[])",
          e.category_uuid,
          type(^category, Ecto.UUID),
          e.option_pairs,
          ^pairs,
          e.tags,
          ^tags
        ),
      order_by: [
        desc:
          fragment(
            "CASE WHEN ? = ? THEN 1 ELSE 0 END",
            e.category_uuid,
            type(^category, Ecto.UUID)
          ),
        desc:
          fragment(
            "cardinality(ARRAY(SELECT unnest(?) INTERSECT SELECT unnest(?::text[]))) + cardinality(ARRAY(SELECT unnest(?) INTERSECT SELECT unnest(?::text[])))",
            e.option_pairs,
            ^pairs,
            e.tags,
            ^tags
          ),
        desc:
          fragment(
            "CASE WHEN ?::numeric IS NOT NULL AND ? BETWEEN ?::numeric * 0.5 AND ?::numeric * 1.5 THEN 1 ELSE 0 END",
            ^price,
            e.price,
            ^price,
            ^price
          ),
        desc_nulls_last: e.item_inserted_at,
        asc: e.item_uuid
      ],
      limit: ^limit,
      select: e.item_uuid
    )
    |> RepoHelper.repo().all()
  end

  @doc "An opaque cursor for `offset`."
  @spec encode_cursor(non_neg_integer()) :: String.t()
  def encode_cursor(offset) when is_integer(offset) and offset >= 0 do
    Base.url_encode64("o:" <> Integer.to_string(offset), padding: false)
  end

  @doc "The offset a cursor stands for. `nil` and `\"\"` are the first page; anything else that is not a cursor of ours is `:error`."
  @spec decode_cursor(String.t() | nil) :: {:ok, non_neg_integer()} | :error
  def decode_cursor(nil), do: {:ok, 0}
  def decode_cursor(""), do: {:ok, 0}

  def decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 64 do
    with {:ok, "o:" <> number} <- Base.url_decode64(cursor, padding: false),
         {offset, ""} when offset >= 0 and offset <= @max_offset <- Integer.parse(number) do
      {:ok, offset}
    else
      _other -> :error
    end
  end

  def decode_cursor(_other), do: :error

  @doc """
  The cursor of the page after `offset` + `limit`, or `nil` on the last page or
  beyond the #{@max_offset} products a cursor can reach.
  """
  @spec next_cursor(non_neg_integer(), pos_integer(), non_neg_integer()) :: String.t() | nil
  def next_cursor(offset, limit, count) do
    next = offset + limit
    if next < count and next <= @max_offset, do: encode_cursor(next)
  end

  # --- filters ---------------------------------------------------------------

  defp filtered(language, params) do
    from(e in Entry, where: e.language == ^language)
    |> by_category(params.category_id)
    |> by_price(params.price_min, params.price_max)
    |> by_options(params.options)
    |> by_vendor(params.vendor)
    |> by_flag(:on_sale, params.on_sale)
    |> by_flag(:made_to_order, params.made_to_order)
  end

  defp by_category(query, nil), do: query

  defp by_category(query, id) do
    where(
      query,
      [e],
      fragment("? @> ?", e.category_path_uuids, type(^[id], {:array, Ecto.UUID}))
    )
  end

  defp by_price(query, nil, nil), do: query
  defp by_price(query, min, nil), do: where(query, [e], e.price >= ^min)
  defp by_price(query, nil, max), do: where(query, [e], e.price <= ^max)
  defp by_price(query, min, max), do: where(query, [e], e.price >= ^min and e.price <= ^max)

  defp by_options(query, options) when map_size(options) == 0, do: query

  defp by_options(query, options) do
    Enum.reduce(options, query, fn {key, values}, acc ->
      pairs = Enum.map(values, &"#{key}:#{&1}")
      # `?::text[]`, not `type(^pairs, {:array, :string})`: Ecto would send
      # `$n::varchar[]` and Postgres has no operator `text[] && varchar[]`
      # (Postgrex.Error 42883 on every call).
      where(acc, [e], fragment("? && ?::text[]", e.option_pairs, ^pairs))
    end)
  end

  defp by_vendor(query, nil), do: query

  defp by_vendor(query, vendor),
    do: where(query, [e], fragment("lower(?) = lower(?)", e.vendor, ^vendor))

  defp by_flag(query, _field, nil), do: query
  defp by_flag(query, :on_sale, value), do: where(query, [e], e.on_sale == ^value)
  defp by_flag(query, :made_to_order, value), do: where(query, [e], e.made_to_order == ^value)

  # --- matching and order ----------------------------------------------------

  defp match(query, %{q: nil}, _language), do: {query, :browse}

  defp match(query, %{q: q}, language) do
    config = Dictionary.regconfig(language)

    fulltext =
      where(
        query,
        [e],
        fragment(
          "? @@ websearch_to_tsquery(?::text::regconfig, ?::text)",
          e.document,
          ^config,
          ^q
        )
      )

    case fulltext_probe(fulltext) do
      :error ->
        # Defence in depth: `clean_q/1` already removes the inputs that make
        # websearch_to_tsquery raise. If Postgres still refuses a text, the
        # answer is "no match" (mode :browse keeps the order clause free of
        # the tsquery), never a 500.
        {where(query, [e], false), :browse}

      true ->
        {fulltext, :fulltext}

      false ->
        typo_or_empty(query, q, fulltext)
    end
  end

  defp fulltext_probe(fulltext) do
    RepoHelper.repo().exists?(fulltext)
  rescue
    error in Postgrex.Error ->
      Logger.warning("[Search] full-text probe refused: #{Exception.message(error)}")
      :error
  end

  # `title_trgm %> q` is `word_similarity(q, title_trgm) >= threshold` written
  # as an operator, which is the form the `gin_trgm_ops` index of V4 can serve
  # (a plain `word_similarity(...) >= x` call cannot use it). The threshold is
  # set per transaction in `in_typo_transaction/1`.
  defp typo_or_empty(query, q, fulltext) do
    if Trigram.available?() do
      typo = where(query, [e], fragment("? %> ?::text", e.title_trgm, ^String.downcase(q)))

      {typo, :typo}
    else
      {fulltext, :fulltext}
    end
  end

  defp ordered(query, :fulltext, %{sort: :relevance, q: q}, language) do
    config = Dictionary.regconfig(language)

    order_by(query, [e],
      desc:
        fragment(
          "ts_rank_cd(?, websearch_to_tsquery(?::text::regconfig, ?::text))",
          e.document,
          ^config,
          ^q
        ),
      asc: e.title,
      asc: e.item_uuid
    )
  end

  defp ordered(query, :typo, %{sort: :relevance, q: q}, _language) do
    order_by(query, [e],
      desc: fragment("word_similarity(?::text, ?)", ^String.downcase(q), e.title_trgm),
      asc: e.title,
      asc: e.item_uuid
    )
  end

  defp ordered(query, _mode, %{sort: :relevance}, _language),
    do: order_by(query, [e], asc: e.sort_position, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :price_asc}, _language),
    do: order_by(query, [e], asc_nulls_last: e.price, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :price_desc}, _language),
    do: order_by(query, [e], desc_nulls_last: e.price, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :discount_desc}, _language),
    do: order_by(query, [e], desc_nulls_last: e.discount_pct, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :newest}, _language),
    do: order_by(query, [e], desc_nulls_last: e.item_inserted_at, asc: e.title, asc: e.item_uuid)

  # --- facets ----------------------------------------------------------------

  defp facets(matched) do
    rows =
      matched
      |> select([e], %{
        category_uuid: e.category_uuid,
        vendor: e.vendor,
        option_pairs: e.option_pairs,
        option_labels: e.option_labels,
        on_sale: e.on_sale,
        made_to_order: e.made_to_order,
        price: e.price
      })
      |> order_by([e], asc: e.item_uuid)
      |> limit(^@facet_cap)
      |> RepoHelper.repo().all()

    %{
      categories: rows |> Enum.map(& &1.category_uuid) |> frequencies(),
      vendors: rows |> Enum.map(& &1.vendor) |> frequencies(),
      options: option_facets(rows),
      on_sale: Enum.count(rows, & &1.on_sale),
      made_to_order: Enum.count(rows, & &1.made_to_order),
      price: price_range(rows)
    }
  end

  defp frequencies(values), do: values |> Enum.reject(&is_nil/1) |> Enum.frequencies()

  defp option_facets(rows) do
    rows
    |> Enum.flat_map(fn row -> Enum.map(row.option_pairs, &{&1, row.option_labels}) end)
    |> Enum.reduce(%{}, fn {pair, labels}, acc ->
      Map.update(acc, pair, %{count: 1, labels: labels}, &%{&1 | count: &1.count + 1})
    end)
    |> Enum.flat_map(fn {pair, %{count: count, labels: labels}} ->
      case String.split(pair, ":", parts: 2) do
        [key, value] ->
          [
            %{
              pair: pair,
              key: key,
              value: value,
              label: Map.get(labels, pair, value),
              set_label: Map.get(labels, key, key),
              count: count
            }
          ]

        _malformed ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.key, -&1.count, &1.value})
  end

  defp price_range(rows) do
    case rows |> Enum.map(& &1.price) |> Enum.reject(&is_nil/1) do
      [] -> nil
      prices -> {Enum.min(prices, Decimal), Enum.max(prices, Decimal)}
    end
  end
end
