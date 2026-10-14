defmodule PhoenixKitEcommerce.Search.OptionKeys do
  @moduledoc """
  The language-neutral option keys of a product (an option is
  `{attribute_key, value_key}`), read from the metadata both product sources
  keep: `_option_values` (key to labels, in the language the view was built
  for), `_value_slugs` (key to label to value slug; catalogue source),
  `_option_labels` (key to the set's display name) and `_price_modifiers`.

  A value with no slug entry gets `PhoenixKit.Utils.Slug.slugify/2` of its
  label, so a legacy product and a catalogue item expose the same shape.
  """

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce.Options

  @type value :: %{key: String.t(), label: String.t()}
  @type option :: %{
          key: String.t(),
          label: String.t(),
          affects_price: boolean(),
          values: [value()]
        }

  @doc """
  The options of `product`, sorted by key; options without a usable value are
  left out, and sets whose keys collapse to one key (`"a:b"` and `"a_b"`) are
  merged into one option.
  """
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
      raw_key = to_string(raw_key)
      key = neutral_key(raw_key)
      entries = entries(slugs, raw_key, key, labels)

      if entries == [] do
        []
      else
        [
          %{
            key: key,
            label: set_label(names, raw_key),
            affects_price: Options.has_nonzero_modifiers?(Map.get(modifiers, raw_key)),
            values: entries
          }
        ]
      end
    end)
    |> Enum.group_by(& &1.key)
    |> Enum.sort_by(fn {key, _group} -> key end)
    |> Enum.map(fn {_key, [first | rest]} -> Enum.reduce(rest, first, &merge/2) end)
  end

  @doc """
  The language-neutral form of an attribute key: trimmed, and without a colon,
  because the pair format is `key:value`.
  """
  @spec neutral_key(String.t()) :: String.t()
  def neutral_key(key) when is_binary(key), do: key |> String.trim() |> neutral()

  @doc """
  The value key `extract/1` announces for `label` of the option `raw_key` of
  `product` (any map with `:metadata`): the catalogue's slug when the product
  has one, else the slugified label. A caller that has to turn a key a client
  sends back into a label (the cart) goes through this, never a rule of its own.
  """
  @spec product_value_key(map(), String.t(), String.t()) :: String.t()
  def product_value_key(%{metadata: metadata}, raw_key, label) do
    slugs = metadata |> map() |> Map.get("_value_slugs") |> map()
    value_key(slugs, to_string(raw_key), label)
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
        %{key: value_key(slugs, raw_key, label), label: String.trim(label)}
      end

    if key == "", do: [], else: Enum.uniq_by(entries, & &1.key)
  end

  defp value_key(slugs, key, label) do
    case slugs |> map() |> Map.get(key) |> map() |> Map.get(label) do
      slug when is_binary(slug) and slug != "" -> neutral(slug)
      _none -> label |> String.trim() |> fallback_key() |> neutral()
    end
  end

  defp fallback_key(label) do
    case Slug.slugify(label) do
      "" -> label |> String.downcase() |> String.replace(~r/\s+/u, "-")
      slug -> slug
    end
  end

  # The pair format is `key:value`, so neither part may hold a colon.
  defp neutral(key), do: String.replace(key, ":", "_")

  # The set's display name, else the same humanised key the rest of the module shows.
  defp set_label(names, raw_key) do
    case Map.get(names, raw_key) do
      name when is_binary(name) and name != "" -> name
      _none -> Options.humanize_key(raw_key)
    end
  end

  defp merge(option, acc) do
    %{
      acc
      | affects_price: acc.affects_price or option.affects_price,
        values: Enum.uniq_by(acc.values ++ option.values, & &1.key)
    }
  end

  defp map(%{} = value), do: value
  defp map(_other), do: %{}
end
