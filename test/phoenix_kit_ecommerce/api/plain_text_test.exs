defmodule PhoenixKitEcommerce.API.PlainTextTest do
  @moduledoc """
  Descriptions as plain text from both stored forms: HTML (Legacy source,
  Shopify CSV) and Markdown (Catalogue source: the Shopify sync stores
  `HtmlToMarkdown.convert/1` output in `body_html`). Pure, no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.PlainText

  defp text(raw), do: PlainText.convert(raw, 4_000)

  test "Markdown syntax is removed and the words stay" do
    assert text("A **bold** vase\n\n- item one\n- item two") == "A bold vase item one item two"

    assert text("# Title\n\nSome *italic* and _more_ text with `code`.") ==
             "Title Some italic and more text with code."

    assert text("> quoted\n\n1. first\n2. second") == "quoted first second"
    assert text("~~old~~ new __strong__") == "old new strong"
    assert text("---\nText\n***") == "Text"
  end

  test "links and images keep their text and lose their address" do
    assert text("See [the guide](https://x.test/a_b) and ![alt text](https://x.test/i.png)") ==
             "See the guide and alt text"
  end

  test "tables lose their pipes and their separator row" do
    assert text("| Size | Price |\n|------|-------|\n| S | 5 |") == "Size Price S 5"
  end

  test "HTML is still stripped" do
    assert text("<p>Plain <b>HTML</b> stays</p>") == "Plain HTML stays"
  end

  test "characters that only look like Markdown stay" do
    assert text("5 * 3 * 2 and snake_case_name and 2 > 1") ==
             "5 * 3 * 2 and snake_case_name and 2 > 1"

    assert text("Ceramic vase with *rim*: handmade") == "Ceramic vase with rim: handmade"
  end

  test "blank input is nil, and the limit applies" do
    assert PlainText.convert(nil, 10) == nil
    assert PlainText.convert("", 10) == nil
    assert PlainText.convert("  \n ", 10) == nil
    assert PlainText.convert(42, 10) == nil
    assert PlainText.convert(String.duplicate("a", 30), 10) == String.duplicate("a", 10)
  end
end
