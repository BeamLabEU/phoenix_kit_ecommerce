defmodule PhoenixKitEcommerce.API.PlainText do
  @moduledoc """
  A description as plain text, from either stored form: HTML or Markdown.

  The Catalogue product source keeps a description in `body_html` as Markdown
  (the Shopify sync converts HTML with `PhoenixKitEcommerce.HtmlToMarkdown`),
  the Legacy source and the CSV import keep HTML. `HtmlText.extract_description/2`
  removes tags only, so Markdown syntax (`**`, `- `, `# `, links) would reach
  the search document and the default card. This module takes out script and
  style blocks, then the Markdown (line-based constructs need the line breaks),
  then the tags, decodes the HTML entities (`HtmlToMarkdown` keeps `&amp; &lt;
  &gt;` encoded in the stored Markdown) and collapses the whitespace, then cuts
  to the limit.

  Text that only looks like Markdown stays: `5 * 3 * 2`, `snake_case_name`,
  `2 > 1`.
  """

  alias PhoenixKitEcommerce.HtmlText

  # A single description is never longer than a few thousand characters; the
  # input is cut at a multiple of the limit before any pattern runs, so one
  # pathological value cannot stall the caller. The multiple leaves room for
  # the markup that is removed again.
  @input_factor 8

  # Longest span the emphasis and link patterns look across. A longer span is
  # left as written: bounded patterns cannot go quadratic on unclosed markers.
  @span 500

  # A link target: anything up to the closing parenthesis, one level of
  # parentheses inside allowed (`/wiki/Foo_(bar)`).
  @target "(?:[^()]|\\([^()]*\\))*"

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "ndash" => "-",
    "mdash" => "-",
    "hellip" => "...",
    "lsquo" => "'",
    "rsquo" => "'",
    "ldquo" => "\"",
    "rdquo" => "\"",
    "copy" => "(c)",
    "reg" => "(R)",
    "trade" => "(TM)"
  }

  @doc "Plain text of `raw`, at most `limit` characters; `nil` for blank or not a string."
  @spec convert(term(), pos_integer()) :: String.t() | nil
  def convert(raw, limit) when is_binary(raw) and is_integer(limit) do
    text =
      raw
      |> String.slice(0, limit * @input_factor)
      |> drop_script_and_style()
      |> close_tags_on_one_line()
      |> strip_markdown()
      |> strip_tags()
      |> decode_entities()
      |> collapse_whitespace()
      |> String.slice(0, limit)
      |> String.trim_trailing()

    if text == "", do: nil, else: text
  end

  def convert(_other, _limit), do: nil

  # A script or style body is code, not text. An unclosed one runs to the end,
  # as a browser reads it.
  defp drop_script_and_style(text) do
    replace(text, ~r/<(script|style)\b(?:(?!<\/\1\s*>).)*(?:<\/\1\s*>|\z)/isu, " ")
  end

  # The line rules of Markdown must not see the inside of a tag: a `>` that
  # starts a line would read as a quote marker and eat the text after it.
  defp close_tags_on_one_line(text) do
    replace(text, ~r/<[a-zA-Z\/!][^<>]{0,2000}>/u, &String.replace(&1, ~r/\s+/u, " "))
  end

  defp strip_markdown(raw) do
    raw
    |> replace(~r/!\[([^\]]{0,#{@span}})\]\(#{@target}\)/u, "\\1")
    |> replace(~r/\[([^\]]{0,#{@span}})\]\(#{@target}\)/u, "\\1")
    |> replace(~r/^\s*(?:`{3,}|~{3,}).*$/mu, "")
    |> replace(~r/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/mu, "")
    |> replace(~r/\\\|/u, "|")
    |> replace(~r/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)*\|?\s*$/mu, "")
    |> replace(~r/^\s*\|.*$/mu, &String.replace(&1, "|", " "))
    |> replace(~r/^\s{0,3}\#{1,6}\s+/mu, "")
    |> replace(~r/^\s{0,3}>\s?/mu, "")
    |> replace(~r/^\s*(?:[-*+]|\d+[.)])\s+/mu, "")
    |> replace(~r/(\*\*|__)(?=\S)(.{1,#{@span}}?)(?<=\S)\1/u, "\\2")
    |> replace(~r/(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])/u, "\\1")
    |> replace(~r/(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])/u, "\\1")
    |> replace(~r/~~(?=\S)(.{1,#{@span}}?)(?<=\S)~~/u, "\\1")
    |> replace(~r/`([^`\n]+)`/u, "\\1")
  end

  defp strip_tags(text), do: HtmlText.extract_description(text, max(byte_size(text), 1)) || ""

  # One pass, so `&amp;lt;` becomes `&lt;` and not `<`. A reference that is not
  # a known name or a valid character stays as written; a control character
  # (a NUL cannot be stored) becomes a space.
  defp decode_entities(text) do
    replace(text, ~r/&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[a-zA-Z]{2,8});/u, &decode_entity/2)
  end

  defp decode_entity(whole, "#" <> number) do
    parsed =
      case number do
        "x" <> hex -> Integer.parse(hex, 16)
        "X" <> hex -> Integer.parse(hex, 16)
        decimal -> Integer.parse(decimal)
      end

    case parsed do
      {code, ""} -> character(code, whole)
      _other -> whole
    end
  end

  defp decode_entity(whole, name), do: Map.get(@entities, name, whole)

  defp character(code, _whole) when code < 0x20 or code in 0x7F..0x9F, do: " "

  defp character(code, whole) when code > 0x10FFFF or code in 0xD800..0xDFFF, do: whole

  defp character(code, _whole), do: <<code::utf8>>

  defp collapse_whitespace(text), do: text |> replace(~r/\s+/u, " ") |> String.trim()

  defp replace(text, regex, replacement), do: Regex.replace(regex, text, replacement)
end
