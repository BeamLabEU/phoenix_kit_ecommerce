defmodule PhoenixKitEcommerce.Search.OptionKeysTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Search.OptionKeys

  defp product(metadata), do: struct(Product, metadata: metadata)

  test "reads keys, labels, value keys and the price flag from the metadata" do
    options =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Large", "Small"], "colour" => ["Red"]},
          "_value_slugs" => %{"size" => %{"Large" => "l-size"}},
          "_option_labels" => %{"size" => "Size"},
          "_price_modifiers" => %{"size" => %{"Large" => "5.00"}}
        })
      )

    assert options == [
             %{
               key: "colour",
               label: "colour",
               affects_price: false,
               values: [%{key: "red", label: "Red"}]
             },
             %{
               key: "size",
               label: "Size",
               affects_price: true,
               values: [%{key: "l-size", label: "Large"}, %{key: "small", label: "Small"}]
             }
           ]
  end

  test "a value without a slug entry is slugified; an unromanizable one keeps its lower-cased words" do
    options =
      OptionKeys.extract(product(%{"_option_values" => %{"mood" => ["Very Nice", "★ ★"]}}))

    [%{values: values}] = options

    assert Enum.map(values, & &1.key) == ["very-nice", "★-★"]
  end

  test "a colon in an option key cannot break the pair format" do
    [option] = OptionKeys.extract(product(%{"_option_values" => %{"a:b" => ["x"]}}))

    assert option.key == "a_b"
    assert OptionKeys.pairs([option]) == ["a_b:x"]
  end

  test "pairs/1 and labels/1" do
    options =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Large"]},
          "_option_labels" => %{"size" => "Size"}
        })
      )

    assert OptionKeys.pairs(options) == ["size:large"]
    assert OptionKeys.labels(options) == %{"size" => "Size", "size:large" => "Large"}
  end

  test "missing, empty or malformed metadata yields no options" do
    assert OptionKeys.extract(product(nil)) == []
    assert OptionKeys.extract(product(%{})) == []
    assert OptionKeys.extract(product(%{"_option_values" => "oops"})) == []
    assert OptionKeys.extract(product(%{"_option_values" => %{"size" => []}})) == []
    assert OptionKeys.extract(product(%{"_option_values" => %{"size" => [1, nil, " "]}})) == []
  end

  test "two labels with one value key collapse into one value" do
    [option] =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Large", "large"]}
        })
      )

    assert [%{key: "large"}] = option.values
  end
end
