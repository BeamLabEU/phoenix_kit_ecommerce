defmodule PhoenixKitEcommerce.Catalogue.SetSlug do
  @moduledoc """
  Normalizes a Shopify option name (e.g. `"Cup Color"`, `"Größe"`) into the
  bare attribute-set slug `Writer.sync_variants/2` looks the catalogue set
  up by (`"catalogue_set_" <> slug` is the blueprint's own `:name`).

  Pure and ASCII-folding-free: it downcases, collapses every run of non
  `[a-z0-9]` characters to a single `_`, and trims `_`. A key that is already
  underscored (`main_color`, `cup_color`) comes out unchanged, so a set
  created from such a key during a data migration still matches. Hyphens and
  accents do not survive (`"Größe"` mangles to `"gr_e"`, see
  `set_slug_test.exs`).
  """

  @doc """
  Normalizes `name` to a slug: downcase, every run of characters outside
  `[a-z0-9]` becomes one `_`, leading/trailing `_` trimmed.

      iex> PhoenixKitEcommerce.Catalogue.SetSlug.normalise("Cup Color")
      "cup_color"

      iex> PhoenixKitEcommerce.Catalogue.SetSlug.normalise("  Size! ")
      "size"
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
