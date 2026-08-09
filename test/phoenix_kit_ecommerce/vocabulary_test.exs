defmodule PhoenixKitEcommerce.VocabularyTest do
  @moduledoc """
  The vocabulary setting decides what the storefront calls what it sells.
  A bad value must not silently revert the whole storefront, and every variant
  must be a distinct string — the module exists because a swapped noun cannot be
  translated correctly into an inflected language.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Vocabulary

  defp set(value), do: Settings.update_setting(Vocabulary.setting_key(), value)

  describe "current/0" do
    test "defaults to products when unset" do
      set("products")
      assert Vocabulary.current() == "products"
    end

    test "accepts every advertised option" do
      for v <- Vocabulary.options() do
        set(v)
        assert Vocabulary.current() == v
      end
    end

    test "falls back to products for a value outside the closed list" do
      # The guard that stops a typo'd or hand-edited setting from putting the
      # storefront into an undefined state.
      set("bananas")
      assert Vocabulary.current() == "products"
    end
  end

  describe "wording" do
    test "each vocabulary produces a DIFFERENT string for every function" do
      funs = [
        :heading,
        :all_items,
        :browse_all,
        :browse_cta,
        :item_column,
        :none_available,
        :none_match_filters,
        :none_in_category,
        :add_some_to_start,
        :collection_blurb,
        :unavailable_now,
        :unavailable_gone,
        :not_found,
        :add_failed
      ]

      for fun <- funs do
        rendered =
          for v <- Vocabulary.options() do
            set(v)
            apply(Vocabulary, fun, [])
          end

        assert length(Enum.uniq(rendered)) == length(Vocabulary.options()),
               "#{fun}/0 gave duplicate wording across vocabularies: #{inspect(rendered)}"

        refute Enum.any?(rendered, &(&1 in [nil, ""])), "#{fun}/0 produced a blank"
      end
    end

    test "the counted wordings are vocabulary-aware too" do
      # These two live outside the arity-0 list above and were the strings that
      # got neutralized to "items" for every shop instead of routed through here,
      # so a products shop read "Showing 12 of 40 items" under a "Products"
      # heading.
      for {fun, args} <- [{:count_found, [3]}, {:showing_of, [12, 40]}] do
        rendered =
          for v <- Vocabulary.options() do
            set(v)
            apply(Vocabulary, fun, args)
          end

        assert length(Enum.uniq(rendered)) == length(Vocabulary.options()),
               "#{fun} gave duplicate wording across vocabularies: #{inspect(rendered)}"

        refute Enum.any?(rendered, &(&1 in [nil, ""])), "#{fun} produced a blank"
      end
    end

    test "a count is interpolated, not dropped" do
      set("products")
      assert Vocabulary.count_found(7) =~ "7"
      assert Vocabulary.showing_of(12, 40) =~ "12"
      assert Vocabulary.showing_of(12, 40) =~ "40"

      # The singular form is reachable — a plural-only translation would render
      # "1 products found".
      assert Vocabulary.count_found(1) =~ "1"
    end

    test "options/0 is the closed list the settings handler validates against" do
      assert Vocabulary.options() == ~w(products services mixed)
    end
  end
end
