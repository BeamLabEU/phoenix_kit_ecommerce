defmodule PhoenixKitEcommerce.NamePrefix do
  @moduledoc """
  Hides a redundant vocabulary prefix from storefront-displayed category
  and product names — "3D Printed Costume Masks" -> "Costume Masks" —
  driven by the `shop_name_prefixes` setting: a comma-separated list of
  prefixes (a shop may have more than one), empty by default so no
  existing install changes behaviour.

  ## Display-time only

  The stored name/title is never rewritten. Category and product names
  in this shop come from Shopify collection/product titles and are
  re-synced from Shopify on every sync run — a persisted rename would
  either be silently overwritten on the next sync, or would have to be
  excluded from sync, which then hides real upstream renames. Stripping
  at read time needs no coordination with the sync at all: `strip/1`
  is a pure string function, called ONLY from
  `PhoenixKitEcommerce.Translations.get_display/3`, which is itself
  called only from storefront render paths. Nothing in the Shopify
  diff/apply path (`PhoenixKitEcommerce.Shopify.ProductDiff`,
  `PhoenixKitEcommerce.Shopify.CollectionSync`) or in an admin edit
  form calls it — both read the raw stored value exactly as before.

  A library cannot ship one shop's vocabulary, so this is a setting
  rather than a hardcoded literal — read through this wrapper, never
  directly, tolerating a malformed stored value by falling back to the
  safe default (no prefixes, i.e. no stripping) rather than raising.
  """

  alias PhoenixKit.Settings

  @setting "shop_name_prefixes"
  @default ""
  @separators ["-", "–", "|", ":"]

  @doc "The setting key, so the settings UI and tests do not re-spell it."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting

  @doc "The configured prefixes to hide, trimmed and with blanks dropped."
  @spec prefixes() :: [String.t()]
  def prefixes do
    @setting
    |> read()
    |> parse()
  end

  @doc """
  Strips the first configured prefix that matches the START of `name`,
  case-insensitively, consuming any following whitespace and then an
  optional `-`/`–`/`|`/`:` separator plus its whitespace.

  Leaves `name` untouched when:
    * no configured prefix matches
    * the prefix match isn't followed by whitespace, a separator, or the
      end of the string (so "3D Printedstuff" is never mangled into
      "stuff")
    * stripping would leave nothing (a category literally named "3D
      Printed" keeps its full name rather than rendering blank)

  Any non-binary (`nil` included) passes through unchanged.
  """
  @spec strip(any()) :: any()
  def strip(name) when is_binary(name) do
    case prefixes() do
      [] -> name
      configured -> strip_first(name, configured) || name
    end
  end

  def strip(other), do: other

  defp strip_first(name, prefixes) do
    Enum.find_value(prefixes, &strip_one(name, &1))
  end

  defp strip_one(_name, ""), do: nil

  defp strip_one(name, prefix) do
    prefix_len = String.length(prefix)

    if String.starts_with?(String.downcase(name), String.downcase(prefix)) do
      rest = String.slice(name, prefix_len..-1//1)
      if boundary?(rest), do: presence(consume_separator(rest))
    end
  end

  defp boundary?(""), do: true

  defp boundary?(rest) do
    case String.next_grapheme(rest) do
      {char, _} -> whitespace?(char) or char in @separators
      nil -> true
    end
  end

  defp whitespace?(char), do: String.trim(char) == ""

  defp consume_separator(rest) do
    trimmed = String.trim_leading(rest)

    case String.next_grapheme(trimmed) do
      {char, remainder} when char in @separators -> String.trim_leading(remainder)
      _ -> trimmed
    end
  end

  defp presence(stripped) do
    if String.trim(stripped) == "", do: nil, else: stripped
  end

  # Settings reads are ETS-cached but can still fail on a cache miss with
  # an unreachable database. Fail to the SAFE default (no prefixes, i.e.
  # every name renders exactly as stored), never to a guessed stripping.
  defp read(key) do
    Settings.get_setting_cached(key, @default)
  rescue
    _ -> @default
  catch
    :exit, _ -> @default
  end

  defp parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse(_), do: []
end
