defmodule PhoenixKitEcommerce.OptionsPricingTest do
  @moduledoc """
  Pricing math. Pure functions, no database.

  `PhoenixKitEcommerce.Options` carries ~2,100 lines of Decimal arithmetic
  and had no tests at all. Writing the first ones surfaced three live
  defects, all fixed here and pinned below — the discount bug in
  particular had been shipping: a percentage surcharge worked while a
  percentage discount silently did nothing.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Options

  defp spec(modifiers, type) do
    [
      %{
        "key" => "o",
        "type" => "select",
        "affects_price" => true,
        "values" => Map.keys(modifiers),
        "price_modifiers" => modifiers,
        "modifier_type" => type
      }
    ]
  end

  defp price(modifiers, type, base) do
    Options.calculate_final_price(spec(modifiers, type), %{"o" => "v"}, Decimal.new(base))
  end

  describe "calculate_final_price/4 — percent modifiers" do
    test "a NEGATIVE percent is applied, not discarded" do
      # The bug: the percent branch was gated on `Decimal.compare(sum, 0) == :gt`,
      # so surcharges applied and discounts were silently dropped. -10% of
      # 100.00 returned 100.00.
      assert Decimal.equal?(price(%{"v" => "-10"}, "percent", "100"), Decimal.new("90.00"))
    end

    test "a positive percent still applies" do
      assert Decimal.equal?(price(%{"v" => "10"}, "percent", "100"), Decimal.new("110.00"))
    end

    test "-100% floors at zero rather than going negative" do
      assert Decimal.equal?(price(%{"v" => "-100"}, "percent", "100"), Decimal.new("0.00"))
    end
  end

  describe "calculate_final_price/4 — fixed modifiers" do
    test "a fixed-only price is rounded to 2dp" do
      # Rounding used to live inside the percent branch, so a fixed-only
      # modifier returned 10.005 — which then hit a DECIMAL(12,2) column and
      # got rounded independently from the line total, breaking
      # `line_total = unit_price * quantity`.
      assert Decimal.equal?(price(%{"v" => "0.005"}, "fixed", "10.00"), Decimal.new("10.01"))
    end

    test "a fixed modifier larger than the price floors at zero" do
      assert Decimal.equal?(price(%{"v" => "-15"}, "fixed", "10.00"), Decimal.new("0.00"))
    end

    test "a zero modifier leaves the base price alone" do
      assert Decimal.equal?(price(%{"v" => "0"}, "fixed", "100"), Decimal.new("100.00"))
    end
  end

  describe "get_price_range/3" do
    test "returns {min, max} in numeric order, not Erlang term order" do
      # `Enum.min/1` and `Enum.max/1` compare %Decimal{} structs field by
      # field rather than by value, so a range spanning 9.99 and 10 came back
      # INVERTED — and this is customer-visible in the storefront's "From $X".
      {min, max} =
        Options.get_price_range(
          spec(%{"a" => "0", "b" => "-0.01"}, "fixed"),
          Decimal.new("10"),
          %{}
        )

      assert Decimal.equal?(min, Decimal.new("9.99")), "min was #{min}"
      assert Decimal.equal?(max, Decimal.new("10")), "max was #{max}"
      refute Decimal.gt?(min, max), "range is inverted: #{min} > #{max}"
    end
  end

  describe "the Decimal ordering trap itself" do
    test "Enum.min/max on Decimals is wrong, which is why helpers exist" do
      # Pinned as executable documentation: if this ever starts passing,
      # Elixir changed and the helpers can go.
      assert Enum.min([Decimal.new("10"), Decimal.new("9.99")]) == Decimal.new("10")

      assert Decimal.equal?(
               Decimal.min(Decimal.new("10"), Decimal.new("9.99")),
               Decimal.new("9.99")
             )
    end
  end
end
