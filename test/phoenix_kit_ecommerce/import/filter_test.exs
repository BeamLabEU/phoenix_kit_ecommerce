defmodule PhoenixKitEcommerce.Import.FilterTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Import.Filter
  alias PhoenixKitEcommerce.ImportConfig

  defp rows(title, handle \\ "a-product"), do: [%{"Title" => title, "Handle" => handle}]

  for {label, config} <- [
        {"no config", quote(do: nil)},
        {"the default config", quote(do: ImportConfig.default_config())}
      ] do
    describe "with #{label}" do
      test "takes a product whatever its title says" do
        config = unquote(config)

        assert Filter.should_include?(rows("Cotton Shirt"), config)
        assert Filter.should_include?(rows("Wall Art Poster"), config)
      end

      test "still drops a pseudo-product by its handle" do
        refute Filter.should_include?(rows("Express", "express-shipping"), unquote(config))
      end

      test "puts every product in the fallback category" do
        assert Filter.categorize("Ceramic Vase", unquote(config)) == "other"
      end
    end
  end

  describe "with keywords" do
    setup do
      %{
        config: %ImportConfig{
          include_keywords: ["shirt"],
          exclude_keywords: ["sample"],
          exclude_phrases: ["gift card"],
          category_rules: [%{"keywords" => ["shirt"], "slug" => "shirts"}],
          default_category_slug: "misc"
        }
      }
    end

    test "takes a title that matches and no exclusion", %{config: config} do
      assert Filter.should_include?(rows("Cotton Shirt"), config)
    end

    test "skips a title with no include keyword", %{config: config} do
      refute Filter.should_include?(rows("Ceramic Mug"), config)
    end

    test "skips a title with an excluded word or phrase", %{config: config} do
      refute Filter.should_include?(rows("Shirt Sample"), config)
      refute Filter.should_include?(rows("Shirt Gift Card"), config)
    end

    test "places a title by its rule, then by the config's own fallback", %{config: config} do
      assert Filter.categorize("Cotton Shirt", config) == "shirts"
      assert Filter.categorize("Ceramic Mug", config) == "misc"
    end
  end

  test "skip_filter takes even a pseudo-product" do
    assert Filter.should_include?(rows("Express", "express-shipping"), %ImportConfig{
             skip_filter: true
           })
  end
end
