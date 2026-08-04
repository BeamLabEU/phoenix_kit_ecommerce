defmodule PhoenixKitEcommerce.Import.PromUaFormat do
  @moduledoc """
  Prom.ua CSV format adapter implementing `ImportFormat` behaviour.

  Handles the Prom.ua export format:
  - One row = one product (no variant grouping)
  - Bilingual: Russian + Ukrainian titles/descriptions
  - Multiple images comma-separated in a single column
  - Ukrainian column names
  - Category by name (`Назва_групи`)
  - Prices in UAH
  """

  @behaviour PhoenixKitEcommerce.Import.ImportFormat

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Translations

  require Logger

  # Prom.ua CSVs use comma separator (standard CSV)
  NimbleCSV.define(PromUaCSV, separator: ",", escape: "\"")

  @marker_columns ["Назва_позиції", "Ціна", "Номер_групи"]

  @impl true
  def detect?(headers) do
    header_set = MapSet.new(headers)
    Enum.all?(@marker_columns, &MapSet.member?(header_set, &1))
  end

  @impl true
  def requires_option_mapping?, do: false

  @impl true
  def count(path, _config) do
    parse_rows(path) |> length()
  end

  @impl true
  def parse_and_transform(path, categories_map, _config, _opts) do
    parse_rows(path)
    |> Enum.map(fn row -> transform_row(row, categories_map) end)
  end

  @impl true
  def default_config_attrs do
    %{
      name: "prom_ua_default",
      skip_filter: true,
      category_rules: [],
      required_columns: ["Назва_позиції", "Ціна"],
      is_default: false,
      active: true,
      download_images: true,
      include_keywords: [],
      exclude_keywords: [],
      exclude_phrases: [],
      option_mappings: []
    }
  end

  # ============================================
  # PARSING
  # ============================================

  defp parse_rows(path) do
    {headers, rows} =
      path
      |> File.stream!([:utf8])
      |> PromUaCSV.parse_stream(skip_headers: false)
      |> Enum.reduce({nil, []}, fn
        row, {nil, []} ->
          {row, []}

        row, {headers, acc} ->
          # Pad row to match header length (handles short rows)
          padded = pad_row(row, length(headers))
          row_map = Enum.zip(headers, padded) |> Map.new()
          {headers, [row_map | acc]}
      end)

    if headers == nil do
      []
    else
      rows
      |> Enum.reverse()
      |> Enum.filter(fn row ->
        name = row["Назва_позиції"] || ""
        String.trim(name) != ""
      end)
    end
  end

  defp pad_row(row, target_length) when length(row) >= target_length, do: row

  defp pad_row(row, target_length) do
    row ++ List.duplicate("", target_length - length(row))
  end

  # ============================================
  # TRANSFORMATION
  # ============================================

  defp transform_row(row, categories_map) do
    slug = extract_slug(row)
    category_uuid = resolve_category(row, categories_map)
    {price, compare_at_price} = parse_price_and_discount(row)
    image_urls = parse_image_urls(row["Посилання_зображення"])
    images = Enum.map(image_urls, fn url -> %{"src" => url} end)

    %{
      slug: bilingual_map(slug),
      title:
        localized_map(
          non_empty(row["Назва_позиції"]) || "",
          non_empty(row["Назва_позиції_укр"]) || ""
        ),
      body_html: localized_map(row["Опис"] || "", row["Опис_укр"] || ""),
      description:
        localized_map(extract_description(row["Опис"]), extract_description(row["Опис_укр"])),
      seo_title:
        localized_map(
          non_empty(row["HTML_заголовок"]) || "",
          non_empty(row["HTML_заголовок_укр"]) || ""
        ),
      seo_description:
        localized_map(non_empty(row["HTML_опис"]) || "", non_empty(row["HTML_опис_укр"]) || ""),
      vendor: non_empty(row["Виробник"]),
      tags: parse_tags(row["Пошукові_запити"]),
      status: parse_availability(row["Наявність"]),
      price: price,
      compare_at_price: compare_at_price,
      product_type: "physical",
      requires_shipping: true,
      taxable: true,
      featured_image: List.first(image_urls),
      images: images,
      category_uuid: category_uuid,
      weight_grams: parse_weight(row["Вага,кг"]),
      metadata: build_metadata(row)
    }
  end

  # ============================================
  # SLUG
  # ============================================

  defp extract_slug(row) do
    url = row["Продукт_на_сайті"] || ""

    slug =
      case Regex.run(~r|/p\d+-(.+?)\.html|, url) do
        [_, slug_part] -> slug_part
        _ -> nil
      end

    slug = slug || fallback_slug(row)
    slug
  end

  defp fallback_slug(row) do
    uid = non_empty(row["Унікальний_ідентифікатор"])

    if uid do
      "prom-#{uid}"
    else
      # Last resort: generate from product name
      name = row["Назва_позиції"] || "product"

      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 60)
    end
  end

  defp bilingual_map(value) do
    default_lang = Translations.default_language()

    %{"ru" => value, "uk" => value}
    |> maybe_put_default_lang(default_lang, value)
  end

  # Ensure the system's default language key is always present in localized maps.
  # Uses the Russian value as fallback for the default language.
  defp localized_map(ru_value, uk_value) do
    default_lang = Translations.default_language()

    %{"ru" => ru_value, "uk" => uk_value}
    |> maybe_put_default_lang(default_lang, ru_value)
  end

  defp maybe_put_default_lang(map, lang, _fallback) when lang in ["ru", "uk"], do: map
  defp maybe_put_default_lang(map, lang, fallback), do: Map.put_new(map, lang, fallback)

  # ============================================
  # CATEGORY
  # ============================================

  defp resolve_category(row, categories_map) do
    group_name = non_empty(row["Назва_групи"])
    group_number = non_empty(row["Номер_групи"])

    if group_name do
      # Build a slug from the group number for lookup
      category_slug = if group_number, do: "group-#{group_number}", else: slugify(group_name)

      case Map.get(categories_map, category_slug) do
        nil ->
          # Auto-create category with ru name and generated slug
          maybe_create_prom_category(group_name, category_slug)

        category_uuid ->
          category_uuid
      end
    else
      nil
    end
  end

  defp maybe_create_prom_category(group_name, slug) do
    lang = Translations.default_language()

    case Shop.get_category_by_slug_localized(slug, lang) do
      {:ok, %{uuid: uuid}} ->
        uuid

      {:error, :not_found} ->
        attrs = %{
          name: localized_map(group_name, group_name),
          slug: localized_map(slug, slug),
          status: "active"
        }

        case Shop.create_category(attrs) do
          {:ok, category} ->
            Logger.info("Auto-created Prom.ua category: #{slug} (#{group_name})")
            category.uuid

          {:error, changeset} ->
            Logger.warning("Failed to create category #{slug}: #{inspect(changeset.errors)}")
            nil
        end
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-zа-яёіїєґ0-9\s-]/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.slice(0, 80)
  end

  # ============================================
  # PRICE & DISCOUNT
  # ============================================

  defp parse_price_and_discount(row) do
    price_str = row["Ціна"]
    discount_str = row["Знижка"] || ""

    # An unreadable price must FAIL the row, not become free stock.
    #
    # `parse_money/1` was hardened to return nil rather than a truncated
    # number — and this call site turned that nil straight into
    # `Decimal.new(0)`, so a junk or missing price cell put the product on
    # sale for nothing. Refusing to guess is only useful if the caller also
    # refuses.
    #
    # Passing the nil through is what fails it: `Product.changeset/2` has
    # `validate_required([:price])`, so the row is rejected with a real
    # changeset error that the import worker already counts and records
    # against that row — no new error channel, and the operator sees which
    # line was bad instead of finding a free product later.
    case parse_money(price_str) do
      nil ->
        {nil, nil}

      price ->
        {price, calculate_compare_at_price(price, String.trim(discount_str))}
    end
  end

  @doc false
  # Parse a money value from a supplier CSV, tolerating the formats
  # suppliers actually send while REFUSING to silently truncate.
  #
  # `Decimal.parse/1` returns `{decimal, remainder}` and every call site
  # here matched `{decimal, _}`, discarding the remainder — so "12,50"
  # imported as 12 and "1,234.56" imported as 1. No error surfaced: the
  # product simply went on sale at a fraction of its price.
  #
  # Separator handling: whichever of `.` or `,` appears LAST is the decimal
  # separator and the other is a thousands separator; a lone `,` followed
  # by exactly two digits is a decimal comma. Anything still unparsed after
  # normalisation returns nil rather than a truncated number.
  def parse_money(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      # currency symbols/codes and spacing, incl. non-breaking spaces
      |> String.replace(~r/[^\d.,\-]/u, "")
      |> normalize_separators()

    case normalized do
      :error ->
        nil

      value ->
        case Decimal.parse(value) do
          {decimal, ""} -> decimal
          _ -> nil
        end
    end
  end

  def parse_money(_), do: nil

  defp normalize_separators(str) do
    last_dot = last_index(str, ".")
    last_comma = last_index(str, ",")

    cond do
      is_nil(last_dot) and is_nil(last_comma) ->
        str

      is_nil(last_comma) ->
        collapse(str, ".")

      is_nil(last_dot) ->
        collapse(str, ",")

      last_dot > last_comma ->
        # "1,234.56" — comma groups thousands, dot is the decimal point
        mixed(str, ".", ",")

      true ->
        # "1.234,56" — dot groups thousands, comma is the decimal point
        mixed(str, ",", ".")
    end
  end

  # Both separators present: the LAST one is the decimal point, the other
  # groups thousands. Validate the grouping on the integer part only —
  # checking the whole string would see the decimal fraction as a malformed
  # group and reject "1,234.56", which is the single most common supplier
  # format there is.
  defp mixed(str, decimal_sep, group_sep) do
    case String.split(str, decimal_sep) do
      [int_part, frac] ->
        if grouped?(int_part, group_sep) do
          String.replace(int_part, group_sep, "") <> "." <> frac
        else
          :error
        end

      _ ->
        :error
    end
  end

  # Decide whether a single repeated separator is a decimal point or
  # thousands grouping, by VALIDATING the group widths rather than guessing
  # from the tail length.
  #
  # The old rule was "a tail of 1-2 digits means decimal, otherwise
  # thousands", which silently multiplied real prices by 10,000:
  #
  #     "1.2345"    -> 12345      (meant 1.2345)
  #     "1234.5678" -> 12345678   (meant 1234.5678)
  #
  # A thousands separator is ALWAYS followed by exactly three digits, and
  # every group after the first must be exactly three — so "1.2345" and
  # "1,23,45" cannot be grouping, and "1234.5678" is unambiguously decimal.
  # A 3-digit tail with a valid leading group ("1.234") stays genuinely
  # ambiguous between 1234 and 1.234; it is read as grouping, which is the
  # convention these supplier feeds use. Anything that is neither a clean
  # decimal nor clean grouping returns `:error` rather than a plausible
  # wrong number — "1,2,3" used to import as 12.3.
  defp collapse(str, sep) do
    case String.split(str, sep) do
      [single] ->
        single

      [head | rest] = parts ->
        tail = List.last(parts)

        cond do
          # One separator with a non-3-digit tail: decimal point.
          length(rest) == 1 and String.length(tail) != 3 ->
            head <> "." <> tail

          # Uniform 3-digit groups with a valid leading group: thousands.
          grouped_parts?(parts) ->
            Enum.join(parts, "")

          # One separator and a 3-digit tail, but the leading group cannot
          # be a thousands group — "0.001" (zero-padded) or "1234.567"
          # (too wide). Grouping is impossible, so it is a decimal point.
          length(rest) == 1 ->
            head <> "." <> tail

          # Several separators that do not form clean groups: "1,2,3".
          # Refuse rather than invent a number.
          true ->
            :error
        end
    end
  end

  defp grouped?(str, sep), do: str |> String.split(sep) |> grouped_parts?()

  defp grouped_parts?([head | rest]) do
    rest != [] and valid_lead_group?(head) and
      Enum.all?(rest, &(String.length(&1) == 3 and numeric?(&1)))
  end

  defp valid_lead_group?(head) do
    # A leading "-" is part of the number, not the group width.
    digits = String.trim_leading(head, "-")

    # A thousands group is never zero-padded, so a leading "0" means this
    # cannot be grouping: "0.001" is one thousandth, not the integer 1,
    # which is what treating its 3-digit tail as a group produced.
    not String.starts_with?(digits, "0") and
      String.length(digits) in 1..3 and numeric?(digits)
  end

  defp numeric?(s), do: s != "" and String.match?(s, ~r/^\d+$/)

  # Byte position of the LAST occurrence, or nil. Must be a position, not a
  # count: the whole point is comparing where `.` and `,` sit relative to
  # each other, and "1,234.56" has one of each, so any count-based version
  # reports a tie and picks the wrong separator as the decimal one.
  defp last_index(str, sep) do
    case :binary.matches(str, sep) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp calculate_compare_at_price(_price, ""), do: nil

  defp calculate_compare_at_price(price, discount_str) do
    if String.ends_with?(discount_str, "%") do
      calculate_percentage_compare_price(price, String.trim_trailing(discount_str, "%"))
    else
      calculate_absolute_compare_price(price, discount_str)
    end
  end

  defp calculate_percentage_compare_price(price, percent_str) do
    case parse_money(percent_str) do
      nil ->
        nil

      percent ->
        divisor = Decimal.sub(Decimal.new(1), Decimal.div(percent, Decimal.new(100)))

        if Decimal.gt?(divisor, Decimal.new(0)),
          do: Decimal.div(price, divisor) |> Decimal.round(2)
    end
  end

  defp calculate_absolute_compare_price(price, discount_str) do
    case parse_money(discount_str) do
      nil ->
        nil

      absolute_discount ->
        if Decimal.gt?(absolute_discount, Decimal.new(0)),
          do: Decimal.add(price, absolute_discount)
    end
  end

  # ============================================
  # IMAGES
  # ============================================

  defp parse_image_urls(nil), do: []
  defp parse_image_urls(""), do: []

  defp parse_image_urls(urls_string) do
    urls_string
    |> String.split(", ")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ============================================
  # AVAILABILITY
  # ============================================

  defp parse_availability(nil), do: "draft"
  defp parse_availability(""), do: "draft"

  defp parse_availability(value) do
    trimmed = String.trim(value)

    cond do
      trimmed in ["+", "!", "@"] -> "active"
      trimmed == "-" || trimmed == "0" -> "draft"
      # Numeric values > 0 mean in stock
      match?({n, ""} when n > 0, Integer.parse(trimmed)) -> "active"
      true -> "draft"
    end
  end

  # ============================================
  # WEIGHT
  # ============================================

  defp parse_weight(nil), do: nil
  defp parse_weight(""), do: nil

  defp parse_weight(kg_str) do
    case Float.parse(String.trim(kg_str)) do
      {kg, _} -> round(kg * 1000)
      :error -> nil
    end
  end

  # ============================================
  # TAGS
  # ============================================

  defp parse_tags(nil), do: []
  defp parse_tags(""), do: []

  defp parse_tags(tags_str) do
    tags_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # ============================================
  # DESCRIPTION
  # ============================================

  defp extract_description(nil), do: ""
  defp extract_description(""), do: ""

  defp extract_description(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 500)
  end

  # ============================================
  # METADATA
  # ============================================

  defp build_metadata(row) do
    metadata = %{}

    metadata = put_if_present(metadata, "sku", row["Код_товару"])
    metadata = put_if_present(metadata, "prom_id", row["Ідентифікатор_товару"])
    metadata = put_if_present(metadata, "prom_uid", row["Унікальний_ідентифікатор"])
    metadata = put_if_present(metadata, "country", row["Країна_виробник"])
    metadata = put_if_present(metadata, "currency", row["Валюта"])
    metadata = put_if_present(metadata, "group_id", row["Номер_групи"])

    metadata
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, String.trim(value))

  # ============================================
  # HELPERS
  # ============================================

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value), do: String.trim(value)
end
