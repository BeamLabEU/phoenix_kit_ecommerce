defmodule PhoenixKitEcommerce.Catalogue.ItemCommerceRelatedTest do
  @moduledoc """
  The two hand-picked product lists of a catalogue item
  (`data["ecommerce"]`): what `ItemCommerce.cast/2` stores.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Catalogue.Extension
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce

  test "the lists default to empty" do
    assert {:ok, map} = ItemCommerce.cast(%{}, nil)
    assert map["related_product_uuids"] == []
    assert map["cross_sell_product_uuids"] == []
  end

  test "well-formed distinct uuids are stored in order" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    assert {:ok, map} =
             ItemCommerce.cast(
               %{
                 "related_product_uuids" => [b, a, b],
                 "cross_sell_product_uuids" => [a]
               },
               nil
             )

    assert map["related_product_uuids"] == [b, a]
    assert map["cross_sell_product_uuids"] == [a]
  end

  test "blank entries, wrong shapes and the sentinel of an emptied picker are dropped" do
    a = Ecto.UUID.generate()

    assert {:ok, map} =
             ItemCommerce.cast(
               %{
                 "related_product_uuids" => ["", a, 5, nil, true, %{"x" => 1}, "nope"],
                 "cross_sell_product_uuids" => [""]
               },
               %{"cross_sell_product_uuids" => [a]}
             )

    assert map["related_product_uuids"] == [a]
    assert map["cross_sell_product_uuids"] == []
  end

  test "a value that is not a list stores an empty list" do
    assert {:ok, map} = ItemCommerce.cast(%{"related_product_uuids" => "garbage"}, nil)
    assert map["related_product_uuids"] == []
  end

  test "an absent key leaves the stored list alone" do
    a = Ecto.UUID.generate()

    assert {:ok, map} =
             ItemCommerce.cast(%{"vendor" => "Acme"}, %{"related_product_uuids" => [a]})

    assert map["related_product_uuids"] == [a]
  end

  test "a duplicated item keeps both lists" do
    a = Ecto.UUID.generate()

    data = %{
      "related_product_uuids" => [a],
      "cross_sell_product_uuids" => [a],
      "shopify" => %{"handle" => "x"}
    }

    kept = Extension.duplicate_data(:item, data)

    assert kept["related_product_uuids"] == [a]
    assert kept["cross_sell_product_uuids"] == [a]
    refute Map.has_key?(kept, "shopify")
  end

  test "at most the maximum is stored" do
    ids = for _ <- 1..30, do: Ecto.UUID.generate()
    assert {:ok, map} = ItemCommerce.cast(%{"related_product_uuids" => ids}, nil)
    assert length(map["related_product_uuids"]) == PhoenixKitEcommerce.RelatedProducts.max_items()
  end
end
