defmodule PhoenixKitEcommerce.Import.Filter do
  @moduledoc """
  Filter products for import based on configurable rules.

  The keywords and category rules come from an `ImportConfig`. With no config
  nothing is filtered by title: every product is imported, into the fallback
  category, except the pseudo-products `skip_handle?/1` drops.

      config = Shop.get_default_import_config()
      Filter.should_include?(rows, config)
      Filter.categorize(title, config)
  """

  alias PhoenixKitEcommerce.ImportConfig

  # Where a product goes when no rule places it and the config names no
  # fallback of its own.
  @default_category_slug "other"

  # ============================================
  # SHOULD_INCLUDE? FUNCTIONS
  # ============================================

  @doc """
  Check if product should be included in import.

  ## With config

      Filter.should_include?(rows, config)

  Returns true if:
  - Config has `skip_filter: true`, OR
  - Title matches at least one include keyword AND
  - Title does NOT match any exclude keyword/phrase

  ## Without config

      Filter.should_include?(rows)

  Includes every product whose handle is not a pseudo-product.
  """
  def should_include?(rows, config \\ nil)

  def should_include?(rows, %ImportConfig{skip_filter: true}) when is_list(rows), do: true

  def should_include?(rows, %ImportConfig{} = config) when is_list(rows) do
    first_row = List.first(rows)
    title = first_row["Title"] || ""
    handle = first_row["Handle"] || ""

    if skip_handle?(handle) do
      false
    else
      has_include_match?(title, config) and not has_exclude_match?(title, config)
    end
  end

  def should_include?(rows, nil) when is_list(rows) do
    not skip_handle?(List.first(rows)["Handle"] || "")
  end

  # ============================================
  # CATEGORIZE FUNCTIONS
  # ============================================

  @doc """
  Categorize product based on title keywords.

  ## With config

      Filter.categorize(title, config)

  Uses category_rules from config. Returns default_category_slug if no match.

  ## Without config

      Filter.categorize(title)

  Returns the fallback category, `"other"`.
  """
  def categorize(title, config \\ nil)

  def categorize(title, %ImportConfig{} = config) when is_binary(title) do
    title_lower = String.downcase(title)

    find_category_from_config(title_lower, config) || config.default_category_slug ||
      @default_category_slug
  end

  def categorize(title, nil) when is_binary(title), do: @default_category_slug

  # ============================================
  # CONFIG-BASED HELPERS
  # ============================================

  defp has_include_match?(title, %ImportConfig{include_keywords: keywords}) do
    if keywords == [] do
      # No include keywords = include everything
      true
    else
      title_lower = String.downcase(title)
      Enum.any?(keywords, &String.contains?(title_lower, String.downcase(&1)))
    end
  end

  defp has_exclude_match?(title, %ImportConfig{
         exclude_keywords: keywords,
         exclude_phrases: phrases
       }) do
    title_lower = String.downcase(title)

    has_keyword = Enum.any?(keywords || [], &String.contains?(title_lower, String.downcase(&1)))
    has_phrase = Enum.any?(phrases || [], &String.contains?(title_lower, String.downcase(&1)))

    has_keyword or has_phrase
  end

  defp find_category_from_config(title_lower, %ImportConfig{category_rules: rules})
       when is_list(rules) do
    Enum.find_value(rules, fn rule ->
      keywords = rule["keywords"] || rule[:keywords] || []
      slug = rule["slug"] || rule[:slug]
      if rule_matches_title?(keywords, title_lower), do: slug
    end)
  end

  defp find_category_from_config(_title_lower, _config), do: nil

  defp rule_matches_title?(keywords, title_lower) do
    Enum.any?(keywords, fn kw -> String.contains?(title_lower, String.downcase(kw)) end)
  end

  # ============================================
  # SHARED HELPERS
  # ============================================

  defp skip_handle?(handle) do
    handle_lower = String.downcase(handle)

    String.contains?(handle_lower, "shipping") or
      String.contains?(handle_lower, "payment") or
      String.contains?(handle_lower, "gift-card") or
      String.contains?(handle_lower, "custom-order")
  end
end
