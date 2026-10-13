defmodule PhoenixKitEcommerce.Search.OptionKeys do
  @moduledoc """
  The language-neutral option keys of a product (spec 7.3: an option is
  `{attribute_key, value_key}`), read from the metadata both product sources
  keep: `_option_values` (key to labels, in the language the view was built
  for), `_value_slugs` (key to label to value slug; catalogue source),
  `_option_labels` (key to the set's display name) and `_price_modifiers`.

  A value with no slug entry gets `PhoenixKit.Utils.Slug.slugify/2` of its
  label, so a legacy product and a catalogue item expose the same shape.
  """

  alias PhoenixKit.Utils.Slug

  @type value :: %{key: String.t(), label: String.t()}
  @type option :: %{
          key: String.t(),
          label: String.t(),
          affects_price: boolean(),
          values: [value()]
        }

  @doc "The options of `product`, sorted by key; options without a usable value are left out."
  @spec extract(PhoenixKitEcommerce.Product.t()) :: [option()]
  def extract(product) do
    meta = map(product.metadata)
    values = map(meta["_option_values"])
    slugs = map(meta["_value_slugs"])
    names = map(meta["_option_labels"])
    modifiers = map(meta["_price_modifiers"])

    values
    |> Enum.sort_by(fn {key, _labels} -> to_string(key) end)
    |> Enum.flat_map(fn {raw_key, labels} ->
      key = raw_key |> to_string() |> String.replace(":", "_")
      entries = entries(slugs, to_string(raw_key), key, labels)

      case entries do
        [] ->
          []

        _some ->
          [
            %{
              key: key,
              label: set_label(names, to_string(raw_key), key),
              affects_price: Map.has_key?(modifiers, to_string(raw_key)),
              values: entries
            }
          ]
      end
    end)
  end

  @doc "`[\"size:large\", ...]`, sorted and unique."
  @spec pairs([option()]) :: [String.t()]
  def pairs(options) do
    for(option <- options, value <- option.values, do: option.key <> ":" <> value.key)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc ~s|Labels for the set keys and the pairs: `%{"size" => "Size", "size:large" => "Large"}`.|
  @spec labels([option()]) :: %{String.t() => String.t()}
  def labels(options) do
    Enum.reduce(options, %{}, fn option, acc ->
      Enum.reduce(option.values, Map.put(acc, option.key, option.label), fn value, acc ->
        Map.put(acc, option.key <> ":" <> value.key, value.label)
      end)
    end)
  end

  defp entries(slugs, raw_key, key, labels) do
    entries =
      for label <- List.wrap(labels), is_binary(label), String.trim(label) != "" do
        %{key: value_key(slugs, raw_key, label), label: label}
      end

    if key == "", do: [], else: Enum.uniq_by(entries, & &1.key)
  end

  defp value_key(slugs, key, label) do
    case slugs |> map() |> Map.get(key) |> map() |> Map.get(label) do
      slug when is_binary(slug) and slug != "" -> slug
      _none -> fallback_key(label)
    end
  end

  defp fallback_key(label) do
    case Slug.slugify(label) do
      "" -> label |> String.downcase() |> String.replace(~r/\s+/u, "-")
      slug -> slug
    end
  end

  defp set_label(names, raw_key, key) do
    case Map.get(names, raw_key) do
      name when is_binary(name) and name != "" -> name
      _none -> key
    end
  end

  defp map(%{} = value), do: value
  defp map(_other), do: %{}
end
