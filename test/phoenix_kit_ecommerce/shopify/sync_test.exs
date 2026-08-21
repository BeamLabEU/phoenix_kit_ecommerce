defmodule PhoenixKitEcommerce.Shopify.SyncTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
  alias PhoenixKitEcommerce.Shopify.Sync

  defp create_product(attrs) do
    defaults = %{"title" => %{"en" => "Old Title"}, "price" => "10.00", "vendor" => "Old Co"}
    {:ok, product} = Shop.create_product(Map.merge(defaults, attrs))
    product
  end

  defp build_change(product, changes) do
    %Change{
      product_uuid: product.uuid,
      handle: "handle",
      title: "Old Title",
      changes: changes
    }
  end

  describe "apply_change/2 field selection" do
    test "applies only the explicitly requested fields, leaving others untouched" do
      product = create_product(%{})

      c =
        build_change(product, %{
          vendor: %{current: "Old Co", incoming: "New Co"},
          status: %{current: "draft", incoming: "active"}
        })

      assert {:ok, updated} = Sync.apply_change(c, [:vendor])

      assert updated.vendor == "New Co"
      assert updated.status == product.status
    end

    test "with :all, applies every field present in changes" do
      product = create_product(%{})

      c =
        build_change(product, %{
          vendor: %{current: "Old Co", incoming: "New Co"},
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("15.00")}
        })

      assert {:ok, updated} = Sync.apply_change(c, :all)

      assert updated.vendor == "New Co"
      assert Decimal.eq?(updated.price, Decimal.new("15.00"))
    end

    test "ignores a requested field that isn't present in change.changes" do
      product = create_product(%{})

      c = build_change(product, %{vendor: %{current: "Old Co", incoming: "New Co"}})

      assert {:ok, updated} = Sync.apply_change(c, [:vendor, :status])

      assert updated.vendor == "New Co"
      assert updated.status == product.status
    end

    test "defaults to :all when fields is omitted" do
      product = create_product(%{})

      c = build_change(product, %{vendor: %{current: "Old Co", incoming: "New Co"}})

      assert {:ok, updated} = Sync.apply_change(c)
      assert updated.vendor == "New Co"
    end
  end

  describe "apply_change/2 localized field merging" do
    test "merges title, body_html, and description into the base locale only" do
      product =
        create_product(%{
          "title" => %{"en" => "Old Title", "ru" => "Старый заголовок"},
          "body_html" => %{"en" => "<p>Old</p>", "ru" => "<p>Старый</p>"},
          "description" => %{"en" => "Old desc", "ru" => "Старое описание"}
        })

      c =
        build_change(product, %{
          title: %{current: "Old Title", incoming: "New Title"},
          body_html: %{current: "<p>Old</p>", incoming: "<p>New</p>"},
          description: %{current: "Old desc", incoming: "New desc"}
        })

      assert {:ok, updated} = Sync.apply_change(c, :all)

      assert updated.title["en"] == "New Title"
      assert updated.title["ru"] == "Старый заголовок"

      assert updated.body_html["en"] == "<p>New</p>"
      assert updated.body_html["ru"] == "<p>Старый</p>"

      assert updated.description["en"] == "New desc"
      assert updated.description["ru"] == "Старое описание"
    end
  end
end
