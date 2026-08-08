defmodule PhoenixKitEcommerce.Import.Money do
  @moduledoc """
  Money parsing for supplier CSV feeds.

  One implementation, shared by every import format, because the defect it
  exists to prevent showed up independently in two of them:
  `Decimal.parse/1` returns `{decimal, remainder}` and a call site that
  matches `{decimal, _}` discards the remainder, so `"12,50"` imports as
  `12` and `"1,234.56"` imports as `1`. Nothing errors — the product simply
  goes on sale at a fraction of its price.

  `parse/1` tolerates the formats suppliers actually send (currency
  symbols, non-breaking spaces, either separator convention) and returns
  `nil` rather than a truncated or invented number for anything it cannot
  read. Callers are expected to fail the row on `nil`, not substitute zero.
  """

  @doc """
  Parses a money value from a supplier CSV cell.

  Returns a `Decimal`, or `nil` when the value cannot be read
  unambiguously.

  Separator handling: whichever of `.` or `,` appears LAST is the decimal
  separator and the other groups thousands. A single repeated separator is
  resolved by validating group widths, not by guessing from the tail
  length.

  ## Examples

      iex> PhoenixKitEcommerce.Import.Money.parse("12,50")
      Decimal.new("12.50")

      iex> PhoenixKitEcommerce.Import.Money.parse("1.234,56")
      Decimal.new("1234.56")

      iex> PhoenixKitEcommerce.Import.Money.parse("22.80 USD")
      Decimal.new("22.80")

      iex> PhoenixKitEcommerce.Import.Money.parse("1,2,3")
      nil
  """
  @spec parse(term()) :: Decimal.t() | nil
  def parse(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      # currency symbols/codes and spacing, incl. non-breaking spaces
      |> String.replace(~r/[^\d.,\-]/u, "")
      |> normalize_separators()

    case normalized do
      :error ->
        nil

      value ->
        case Decimal.parse(value) do
          {decimal, ""} -> decimal
          _ -> nil
        end
    end
  end

  def parse(_), do: nil

  defp normalize_separators(str) do
    last_dot = last_index(str, ".")
    last_comma = last_index(str, ",")

    cond do
      is_nil(last_dot) and is_nil(last_comma) ->
        str

      is_nil(last_comma) ->
        collapse(str, ".")

      is_nil(last_dot) ->
        collapse(str, ",")

      last_dot > last_comma ->
        # "1,234.56" — comma groups thousands, dot is the decimal point
        mixed(str, ".", ",")

      true ->
        # "1.234,56" — dot groups thousands, comma is the decimal point
        mixed(str, ",", ".")
    end
  end

  # Both separators present: the LAST one is the decimal point, the other
  # groups thousands. Validate the grouping on the integer part only —
  # checking the whole string would see the decimal fraction as a malformed
  # group and reject "1,234.56", which is the single most common supplier
  # format there is.
  defp mixed(str, decimal_sep, group_sep) do
    case String.split(str, decimal_sep) do
      [int_part, frac] ->
        if grouped?(int_part, group_sep) do
          String.replace(int_part, group_sep, "") <> "." <> frac
        else
          :error
        end

      _ ->
        :error
    end
  end

  # Decide whether a single repeated separator is a decimal point or
  # thousands grouping, by VALIDATING the group widths rather than guessing
  # from the tail length.
  #
  # The old rule was "a tail of 1-2 digits means decimal, otherwise
  # thousands", which silently multiplied real prices by 10,000:
  #
  #     "1.2345"    -> 12345      (meant 1.2345)
  #     "1234.5678" -> 12345678   (meant 1234.5678)
  #
  # A thousands separator is ALWAYS followed by exactly three digits, and
  # every group after the first must be exactly three — so "1.2345" and
  # "1,23,45" cannot be grouping, and "1234.5678" is unambiguously decimal.
  # A 3-digit tail with a valid leading group ("1.234") stays genuinely
  # ambiguous between 1234 and 1.234; it is read as grouping, which is the
  # convention these supplier feeds use. Anything that is neither a clean
  # decimal nor clean grouping returns `:error` rather than a plausible
  # wrong number — "1,2,3" used to import as 12.3.
  defp collapse(str, sep) do
    case String.split(str, sep) do
      [single] ->
        single

      [head | rest] = parts ->
        tail = List.last(parts)

        cond do
          # One separator with a non-3-digit tail: decimal point.
          length(rest) == 1 and String.length(tail) != 3 ->
            head <> "." <> tail

          # Uniform 3-digit groups with a valid leading group: thousands.
          grouped_parts?(parts) ->
            Enum.join(parts, "")

          # One separator and a 3-digit tail, but the leading group cannot
          # be a thousands group — "0.001" (zero-padded) or "1234.567"
          # (too wide). Grouping is impossible, so it is a decimal point.
          length(rest) == 1 ->
            head <> "." <> tail

          # Several separators that do not form clean groups: "1,2,3".
          # Refuse rather than invent a number.
          true ->
            :error
        end
    end
  end

  defp grouped?(str, sep), do: str |> String.split(sep) |> grouped_parts?()

  defp grouped_parts?([head | rest]) do
    rest != [] and valid_lead_group?(head) and
      Enum.all?(rest, &(String.length(&1) == 3 and numeric?(&1)))
  end

  defp valid_lead_group?(head) do
    # A leading "-" is part of the number, not the group width.
    digits = String.trim_leading(head, "-")

    # A thousands group is never zero-padded, so a leading "0" means this
    # cannot be grouping: "0.001" is one thousandth, not the integer 1,
    # which is what treating its 3-digit tail as a group produced.
    not String.starts_with?(digits, "0") and
      String.length(digits) in 1..3 and numeric?(digits)
  end

  defp numeric?(s), do: s != "" and String.match?(s, ~r/^\d+$/)

  # Byte position of the LAST occurrence, or nil. Must be a position, not a
  # count: the whole point is comparing where `.` and `,` sit relative to
  # each other, and "1,234.56" has one of each, so any count-based version
  # reports a tie and picks the wrong separator as the decimal one.
  defp last_index(str, sep) do
    case :binary.matches(str, sep) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
