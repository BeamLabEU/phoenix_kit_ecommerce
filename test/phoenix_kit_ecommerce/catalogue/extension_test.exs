defmodule PhoenixKitEcommerce.Catalogue.ExtensionTest do
  @moduledoc """
  Level 1 — component render + pure function tests, no database required.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitEcommerce.Catalogue.Extension

  test "PhoenixKitEcommerce.catalogue_extensions/0 registers the extension" do
    assert PhoenixKitEcommerce.catalogue_extensions() == [Extension]
  end

  test "key/0 is the ecommerce namespace" do
    assert Extension.key() == "ecommerce"
  end

  test "cast_item/2 delegates to ItemCommerce.cast/2" do
    assert {:ok, map} = Extension.cast_item(%{"vendor" => "Acme"}, %{})
    assert map["vendor"] == "Acme"
  end

  test "cast_category/2 delegates to CategoryCommerce.cast/2" do
    assert {:ok, map} = Extension.cast_category(%{"shop_status" => "hidden"}, %{})
    assert map["shop_status"] == "hidden"
  end

  describe "item_section/1" do
    test "renders inputs named item[ecommerce][*]" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(id="ext-ecommerce-section")
      assert html =~ ~s(name="item[ecommerce][shop_status]")
      assert html =~ ~s(name="item[ecommerce][product_type]")
      assert html =~ ~s(name="item[ecommerce][vendor]")
      assert html =~ ~s(name="item[ecommerce][compare_at_price]")
    end

    test "renders the current values from data[\"ecommerce\"]" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{"ecommerce" => %{"vendor" => "Acme Co"}},
          current_language: "en-US"
        )

      assert html =~ "Acme Co"
    end
  end

  describe "category_section/1" do
    test "renders inputs named category[ecommerce][*]" do
      html =
        render_component(&Extension.category_section/1,
          form: nil,
          category: nil,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(id="ext-ecommerce-section")
      assert html =~ ~s(name="category[ecommerce][shop_status]")
    end
  end
end
