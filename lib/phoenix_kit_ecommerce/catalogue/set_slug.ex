defmodule PhoenixKitEcommerce.Catalogue.SetSlug do
  @moduledoc """
  Normalizes a Shopify option name (e.g. `"Cup Color"`, `"Größe"`) into the
  bare attribute-set slug `Writer.sync_variants/2` looks the catalogue set
  up by (`"catalogue_set_" <> slug` is the blueprint's own `:name`).

  Pure, ASCII-folding-free — identical algorithm to the app's
  `Decor3dprint.CatalogueMigration.Mapping.set_slug/1`, generalized to
  start from an arbitrary raw label instead of an already-underscored
  key: downcase, collapse every run of non `[a-z0-9]` characters to a
  single `_`, trim leading/trailing `_`.
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
    |> String.replace(~r/_+/, "_")
  end
end
