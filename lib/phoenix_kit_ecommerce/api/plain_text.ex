defmodule PhoenixKitEcommerce.API.PlainText do
  @moduledoc """
  A description as plain text, from either stored form: HTML or Markdown.

  The Catalogue product source keeps a description in `body_html` as Markdown
  (the Shopify sync converts HTML with `PhoenixKitEcommerce.HtmlToMarkdown`),
  the Legacy source and the CSV import keep HTML. `HtmlText.extract_description/2`
  removes tags only, so Markdown syntax (`**`, `- `, `# `, links) would reach
  the search document and the default card. This module removes the Markdown
  first (line-based constructs need the line breaks), then the tags and the
  whitespace, then cuts to the limit.

  Text that only looks like Markdown stays: `5 * 3 * 2`, `snake_case_name`,
  `2 > 1`.
  """

  alias PhoenixKitEcommerce.HtmlText

  @doc "Plain text of `raw`, at most `limit` characters; `nil` for blank or not a string."
  @spec convert(term(), pos_integer()) :: String.t() | nil
  def convert(raw, limit) when is_binary(raw) and is_integer(limit) do
    case raw |> strip_markdown() |> HtmlText.extract_description(limit) do
      text when text in [nil, ""] -> nil
      text -> text
    end
  end

  def convert(_other, _limit), do: nil

  defp strip_markdown(raw) do
    raw
    |> replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> replace(~r/\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> replace(~r/^\s*(?:`{3,}|~{3,}).*$/mu, "")
    |> replace(~r/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/mu, "")
    |> replace(~r/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$/mu, "")
    |> replace(~r/^\s*\|.*$/mu, &String.replace(&1, "|", " "))
    |> replace(~r/^\s{0,3}\#{1,6}\s+/mu, "")
    |> replace(~r/^\s{0,3}>\s?/mu, "")
    |> replace(~r/^\s*(?:[-*+]|\d+[.)])\s+/mu, "")
    |> replace(~r/(\*\*|__)(?=\S)(.+?)(?<=\S)\1/u, "\\2")
    |> replace(~r/(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])/u, "\\1")
    |> replace(~r/(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])/u, "\\1")
    |> replace(~r/~~(?=\S)(.+?)(?<=\S)~~/u, "\\1")
    |> replace(~r/`([^`\n]+)`/u, "\\1")
  end

  defp replace(text, regex, replacement), do: Regex.replace(regex, text, replacement)
end
