defmodule PhoenixKitEcommerce.Regression.ImportParsingTest do
  @moduledoc """
  Shopify CSV parsing defects found by an adversarial sweep of the import
  subsystem: a feed with unreadable prices published free products, and rows
  with no handle merged into a single product.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Import.CSVParser
  alias PhoenixKitEcommerce.Import.OptionBuilder

  defp write_csv(rows) do
    path =
      Path.join(
        System.tmp_dir!(),
        "shopify-#{System.unique_integer([:positive])}.csv"
      )

    File.write!(path, Enum.join(rows, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "grouping" do
    test "rows with no handle stay separate products" do
      path =
        write_csv([
          "Handle,Title,Variant Price",
          ",Red Vase,10.00",
          ",Blue Lamp,20.00"
        ])

      grouped = CSVParser.parse_and_group(path)

      assert map_size(grouped) == 2, "two handle-less products collapsed into one"

      titles =
        grouped
        |> Map.values()
        |> Enum.map(fn [row | _] -> row["Title"] end)
        |> Enum.sort()

      assert titles == ["Blue Lamp", "Red Vase"]
    end

    test "the derived key comes from the title, so a reordered re-export matches" do
      forward = write_csv(["Handle,Title,Variant Price", ",Red Vase,10.00", ",Blue Lamp,20.00"])
      reversed = write_csv(["Handle,Title,Variant Price", ",Blue Lamp,20.00", ",Red Vase,10.00"])

      assert CSVParser.parse_and_group(forward) |> Map.keys() |> Enum.sort() ==
               CSVParser.parse_and_group(reversed) |> Map.keys() |> Enum.sort()
    end

    test "rows sharing a handle stay one product with its variants" do
      path =
        write_csv([
          "Handle,Title,Option1 Name,Option1 Value,Variant Price",
          "mug,Mug,Size,S,10.00",
          "mug,,Size,L,14.00"
        ])

      grouped = CSVParser.parse_and_group(path)

      assert map_size(grouped) == 1
      assert length(grouped["mug"]) == 2
    end
  end

  describe "pricing" do
    test "a variant set with no readable price yields no price at all" do
      variants = [
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "N/A"}
      ]

      options = OptionBuilder.build_from_variants(variants)

      refute options.base_price,
             "an unreadable price defaulted to zero, publishing a free product"
    end

    test "the base price is the numeric minimum, not the term-order minimum" do
      variants = [
        %{"Option1 Name" => "Size", "Option1 Value" => "L", "Variant Price" => "10.00"},
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "9.99"}
      ]

      options = OptionBuilder.build_from_variants(variants)

      assert Decimal.equal?(options.base_price, Decimal.new("9.99"))
    end

    test "a partially readable variant set still prices from what it can read" do
      variants = [
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "12.00"},
        %{"Option1 Name" => "Size", "Option1 Value" => "L", "Variant Price" => ""}
      ]

      options = OptionBuilder.build_from_variants(variants)

      assert Decimal.equal?(options.base_price, Decimal.new("12.00"))
    end
  end
end
