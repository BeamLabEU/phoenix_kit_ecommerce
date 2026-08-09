defmodule PhoenixKitEcommerce.PriceDisplayLinesTest do
  @moduledoc """
  The snapshot-line predicates every page that renders a cart or order line has
  to agree on. Pure — no database — so these run on a fresh checkout, unlike the
  rest of `PriceDisplayTest`.

  They exist because the question was asked inline in each template and two of
  the five sites got it wrong: the checkout review step and the product page's
  "already in cart" notice formatted an on-request line's stored `unit_price` of
  0 and rendered "1 × 0.00" — the review step being the last page before the
  customer commits.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.PriceDisplay

  describe "line_on_request?/1" do
    test "reads a cart line's metadata" do
      assert PriceDisplay.line_on_request?(%{metadata: %{"price_on_request" => true}})
      refute PriceDisplay.line_on_request?(%{metadata: %{"price_on_request" => false}})
      refute PriceDisplay.line_on_request?(%{metadata: %{}})
      # Only written when true, so a line with no metadata at all is normal.
      refute PriceDisplay.line_on_request?(%{metadata: nil})
    end

    test "reads an order line item, which is a plain map" do
      assert PriceDisplay.line_on_request?(%{"price_on_request" => true})
      refute PriceDisplay.line_on_request?(%{"price_on_request" => false})
      refute PriceDisplay.line_on_request?(%{"type" => "product"})
    end

    test "anything else is not on request" do
      refute PriceDisplay.line_on_request?(nil)
      refute PriceDisplay.line_on_request?("nope")
    end
  end

  describe "any_line_on_request?/1" do
    test "spots a mixed cart, which is the case the disclosure exists for" do
      # One priced line and one on-request line: the total is real, but it is
      # not the whole bill, and nothing on the page said so.
      priced = %{metadata: %{}}
      on_request = %{metadata: %{"price_on_request" => true}}

      assert PriceDisplay.any_line_on_request?([priced, on_request])
      refute PriceDisplay.any_line_on_request?([priced, priced])
    end

    test "handles order lines and the empty and nil cases" do
      assert PriceDisplay.any_line_on_request?([
               %{"type" => "shipping"},
               %{"price_on_request" => true}
             ])

      refute PriceDisplay.any_line_on_request?([])
      refute PriceDisplay.any_line_on_request?(nil)
    end
  end
end
