defmodule PhoenixKitEcommerce.RelatedProductsTest do
  @moduledoc """
  The related-products list: what is stored, what a shopper may be shown, the
  category fallback, and the hook stock will plug into.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Availability
  alias PhoenixKitEcommerce.RelatedProducts

  defp product!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => "Related #{n}"},
            "price" => Decimal.new("5.00"),
            "status" => "active",
            "currency" => "EUR",
            "product_type" => "digital",
            "requires_shipping" => false,
            "weight_grams" => 0
          },
          attrs
        )
      )

    product
  end

  defp category!(status \\ "active") do
    n = System.unique_integer([:positive])

    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Cat #{n}"},
        "slug" => %{"en" => "cat-#{n}"},
        "status" => status
      })

    category
  end

  defp with_related(product, ids) do
    {:ok, product} =
      Shop.update_product(product, %{
        "metadata" => Map.put(product.metadata || %{}, RelatedProducts.metadata_key(), ids)
      })

    product
  end

  defp set_setting(key, value) do
    previous = Settings.get_setting(key, "")
    Settings.update_setting(key, value)
    on_exit(fn -> Settings.update_setting(key, previous) end)
  end

  describe "normalize/2" do
    test "keeps well-formed uuids once, in order, without the product itself" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()
      own = Ecto.UUID.generate()

      assert RelatedProducts.normalize([a, b, a, own, String.upcase(b)], own) == [a, b]
    end

    test "a 16-byte string is not a uuid, only the 36-character text form is" do
      raw = <<1::128>>
      good = Ecto.UUID.generate()

      assert RelatedProducts.normalize([raw, good, String.replace(good, "-", "")]) == [good]
    end

    test "drops every entry that is not a uuid string" do
      a = Ecto.UUID.generate()

      assert RelatedProducts.normalize([a, 5, true, nil, %{"x" => 1}, "nope", ""]) == [a]
    end

    test "anything but a list is empty" do
      for value <- [nil, "x", %{}, 7, true] do
        assert RelatedProducts.normalize(value) == []
      end
    end

    test "stops at the maximum" do
      ids = for _ <- 1..30, do: Ecto.UUID.generate()

      assert length(RelatedProducts.normalize(ids)) == RelatedProducts.max_items()
    end
  end

  describe "uuids/1" do
    test "reads the stored list and survives a stored value of the wrong shape" do
      a = Ecto.UUID.generate()

      assert RelatedProducts.uuids(%{
               uuid: Ecto.UUID.generate(),
               metadata: %{"related_product_uuids" => [a]}
             }) ==
               [a]

      assert RelatedProducts.uuids(%{metadata: %{"related_product_uuids" => "garbage"}}) == []
      assert RelatedProducts.uuids(%{metadata: nil}) == []
      assert RelatedProducts.uuids(nil) == []
    end
  end

  describe "for_product/2" do
    test "returns the picked products in the merchant's order" do
      [a, b, c] = for _ <- 1..3, do: product!()
      main = product!() |> with_related([c.uuid, a.uuid, b.uuid])

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [c.uuid, a.uuid, b.uuid]
    end

    test "leaves out drafts, archived products and products of a hidden category" do
      listed = product!()
      draft = product!(%{"status" => "draft"})
      archived = product!(%{"status" => "archived"})
      hidden = product!(%{"category_uuid" => category!("hidden").uuid})
      unlisted = product!(%{"category_uuid" => category!("unlisted").uuid})

      main =
        product!()
        |> with_related([draft.uuid, hidden.uuid, listed.uuid, archived.uuid, unlisted.uuid])

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [
               listed.uuid,
               unlisted.uuid
             ]
    end

    test "skips an id that points to nothing and one that is the product itself" do
      listed = product!()
      main = product!()
      main = with_related(main, [Ecto.UUID.generate(), main.uuid, listed.uuid])

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [listed.uuid]
    end

    test "shows at most the configured limit" do
      products = for _ <- 1..5, do: product!()
      main = product!() |> with_related(Enum.map(products, & &1.uuid))

      assert length(RelatedProducts.for_product(main)) == 4

      set_setting("shop_related_limit", "2")
      assert length(RelatedProducts.for_product(main)) == 2
      assert length(RelatedProducts.for_product(main, limit: 3)) == 3
    end

    test "a product with no list shows nothing by default" do
      category = category!()
      _sibling = product!(%{"category_uuid" => category.uuid})
      main = product!(%{"category_uuid" => category.uuid})

      assert RelatedProducts.fallback() == :off
      assert RelatedProducts.for_product(main) == []
    end
  end

  describe "the category fallback" do
    setup do
      set_setting("shop_related_fallback", "category")
      :ok
    end

    test "stands in when the product has no list" do
      category = category!()
      sibling = product!(%{"category_uuid" => category.uuid})
      _other_category = product!(%{"category_uuid" => category!().uuid})
      _draft = product!(%{"category_uuid" => category.uuid, "status" => "draft"})
      main = product!(%{"category_uuid" => category.uuid})

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [sibling.uuid]
    end

    test "stands in when nothing the merchant picked can be shown" do
      category = category!()
      sibling = product!(%{"category_uuid" => category.uuid})
      draft = product!(%{"status" => "draft"})
      main = product!(%{"category_uuid" => category.uuid}) |> with_related([draft.uuid])

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [sibling.uuid]
    end

    test "is not used when the merchant's list has something to show" do
      category = category!()
      _sibling = product!(%{"category_uuid" => category.uuid})
      picked = product!()
      main = product!(%{"category_uuid" => category.uuid}) |> with_related([picked.uuid])

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [picked.uuid]
    end

    test "a product without a category has nothing to fall back to" do
      assert RelatedProducts.for_product(product!()) == []
    end
  end

  describe "settings" do
    test "a limit outside 1..12 or not a number is the default" do
      for value <- ["0", "13", "-1", "abc", "4.5", ""] do
        set_setting("shop_related_limit", value)
        assert RelatedProducts.limit() == 4
      end

      set_setting("shop_related_limit", "12")
      assert RelatedProducts.limit() == 12
    end

    test "an unknown fallback value is off" do
      set_setting("shop_related_fallback", "everything")
      assert RelatedProducts.fallback() == :off
    end
  end

  describe "availability" do
    defmodule Hook do
      @moduledoc false
      def available?(%{title: %{"en" => "Related sold out"}}), do: false
      def available?(_product), do: true

      def raises(_product), do: raise("stock service down")
      def exits(_product), do: exit(:timeout)
      def throws(_product), do: throw(:no_stock)
      def one_arg_only(_product, _extra), do: false
      def nothing(_product), do: nil
    end

    setup do
      on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :availability) end)
    end

    test "everything is available until a hook says otherwise" do
      assert Availability.available?(%{})
    end

    test "the hook removes a product from the block" do
      gone = product!(%{"title" => %{"en" => "Related sold out"}})
      kept = product!()
      main = product!() |> with_related([gone.uuid, kept.uuid])

      Application.put_env(:phoenix_kit_ecommerce, :availability, {Hook, :available?})

      assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [kept.uuid]
    end

    test "a hook that is missing, has another arity, raises, exits or throws counts as available" do
      for function <- [:missing, :one_arg_only, :raises, :exits, :throws] do
        Application.put_env(:phoenix_kit_ecommerce, :availability, {Hook, function})

        log = capture_log(fn -> assert Availability.available?(%{}) end)

        assert log =~ "availability hook"
        assert log =~ inspect(function)
      end
    end

    test "only false means unavailable" do
      Application.put_env(:phoenix_kit_ecommerce, :availability, {Hook, :nothing})
      assert Availability.available?(%{})
    end

    test "a failing hook does not empty the block" do
      kept = product!()
      main = product!() |> with_related([kept.uuid])

      Application.put_env(:phoenix_kit_ecommerce, :availability, {Hook, :exits})

      capture_log(fn ->
        assert Enum.map(RelatedProducts.for_product(main), & &1.uuid) == [kept.uuid]
      end)
    end
  end
end
