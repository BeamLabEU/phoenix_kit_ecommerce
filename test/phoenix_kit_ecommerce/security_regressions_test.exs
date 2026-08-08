defmodule PhoenixKitEcommerce.SecurityRegressionsTest do
  @moduledoc """
  Pure-logic guards for the security and correctness fixes.

  Everything here runs without a database. The parts that genuinely need
  one — the billing-profile ownership check, order-session access, the cart
  `is_nil(user_uuid)` guard — are exercised by the LiveView/context suites;
  what is pinned here is the logic that is easy to regress silently and
  cheap to assert: the SAFE DEFAULTS, and the two parsers that were
  producing wrong values without raising.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Import.OptionBuilder
  alias PhoenixKitEcommerce.Import.PromUaFormat
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.Web.Helpers

  describe "policy defaults are the safe ones" do
    # These read through the settings layer. With no rows written (and no DB
    # in this suite) every read must fall back to the secure default rather
    # than to permissive — that fallback IS the security property, so it is
    # worth asserting explicitly rather than trusting the `||` in each reader.

    test "order confirmation pages are not readable by uuid alone" do
      assert Policy.order_lookup_policy() == :strict
    end

    test "product descriptions are sanitized" do
      refute Policy.allow_raw_html_descriptions?()
    end

    test "SVG import is refused" do
      refute Policy.allow_svg_uploads?()
    end

    test "image import cannot reach private networks" do
      refute Policy.image_import_allow_private_networks?()
    end

    test "import cleanup only touches categories the import created" do
      assert Policy.import_cleanup_scope() == :auto_created
    end

    test "there is no guessed tax jurisdiction" do
      assert Policy.default_tax_country() == nil
    end
  end

  describe "private_host?/1 (SSRF guard)" do
    test "blocks loopback, private, link-local and metadata addresses" do
      for host <- [
            "127.0.0.1",
            "10.0.0.5",
            "192.168.1.1",
            "172.16.0.1",
            "172.31.255.255",
            # the cloud metadata service — the payload that makes SSRF pay
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "::1"
          ] do
        assert ImageDownloader.private_host?(host), "#{host} should be blocked"
      end
    end

    test "allows ordinary public addresses" do
      refute ImageDownloader.private_host?("93.184.216.34")
      refute ImageDownloader.private_host?("8.8.8.8")
    end

    test "172.15 and 172.32 are public — the private range is 172.16-31 only" do
      refute ImageDownloader.private_host?("172.15.0.1")
      refute ImageDownloader.private_host?("172.32.0.1")
    end

    test "a name that cannot be resolved fails CLOSED" do
      assert ImageDownloader.private_host?("no-such-host.invalid")
    end

    test "IPv4-mapped IPv6 forms do not bypass the check" do
      # `::ffff:127.0.0.1` parses to {0,0,0,0,0,65535,32512,1}, which
      # matched none of the IPv4 clauses — so every private address had a
      # working bypass just by writing it in mapped form.
      for host <- [
            "::ffff:127.0.0.1",
            "::ffff:169.254.169.254",
            "::ffff:10.0.0.5",
            "::ffff:192.168.1.1",
            "::127.0.0.1"
          ] do
        assert ImageDownloader.private_host?(host), "#{host} should be blocked"
      end
    end

    test "mapped PUBLIC addresses are still allowed" do
      # The unfolding must not blanket-block every mapped address.
      refute ImageDownloader.private_host?("::ffff:8.8.8.8")
    end

    test "real IPv6 ranges are classified, in both directions" do
      # The guard resolves BOTH families now, so genuine v6 answers reach
      # these clauses rather than only ever arriving unfolded from v4.
      assert ImageDownloader.private_host?("fd00::1"), "unique-local should be blocked"
      assert ImageDownloader.private_host?("fe80::1"), "link-local should be blocked"
      refute ImageDownloader.private_host?("2001:4860:4860::8888"), "public v6 is allowed"
    end
  end

  describe "parse_money/1 (import price truncation)" do
    test "does not truncate a decimal comma" do
      # The bug: `Decimal.parse("12,50")` returns {12, ",50"} and the old
      # code matched {decimal, _}, so this product went on sale for 12.
      assert Decimal.equal?(PromUaFormat.parse_money("12,50"), Decimal.new("12.50"))
    end

    test "does not truncate a thousands separator" do
      # "1,234.56" used to import as 1.
      assert Decimal.equal?(PromUaFormat.parse_money("1,234.56"), Decimal.new("1234.56"))
      assert Decimal.equal?(PromUaFormat.parse_money("1.234,56"), Decimal.new("1234.56"))
    end

    test "handles plain values and currency noise" do
      assert Decimal.equal?(PromUaFormat.parse_money("22.80"), Decimal.new("22.80"))
      assert Decimal.equal?(PromUaFormat.parse_money("22.80 USD"), Decimal.new("22.80"))
      assert Decimal.equal?(PromUaFormat.parse_money(" 1500 "), Decimal.new("1500"))
    end

    test "returns nil rather than a truncated number for junk" do
      assert PromUaFormat.parse_money("abc") == nil
      assert PromUaFormat.parse_money("") == nil
      assert PromUaFormat.parse_money(nil) == nil
    end

    test "a 4+ digit tail is a fraction, never thousands grouping" do
      # A thousands separator is ALWAYS followed by exactly three digits.
      # The first rule ("tail of 1-2 digits means decimal") multiplied these
      # by 10,000: "1.2345" imported as 12345.
      assert Decimal.equal?(PromUaFormat.parse_money("1.2345"), Decimal.new("1.2345"))
      assert Decimal.equal?(PromUaFormat.parse_money("12.3456"), Decimal.new("12.3456"))
      assert Decimal.equal?(PromUaFormat.parse_money("1234.5678"), Decimal.new("1234.5678"))
    end

    test "a zero-padded leading group is a fraction, not grouping" do
      # "0.001" has a 3-digit tail, but a thousands group is never
      # zero-padded — reading it as grouping produced the integer 1.
      assert Decimal.equal?(PromUaFormat.parse_money("0.001"), Decimal.new("0.001"))
      assert Decimal.equal?(PromUaFormat.parse_money("0,5"), Decimal.new("0.5"))
    end

    test "clean thousands grouping still parses" do
      assert Decimal.equal?(PromUaFormat.parse_money("1.234"), Decimal.new("1234"))
      assert Decimal.equal?(PromUaFormat.parse_money("1,234"), Decimal.new("1234"))
      assert Decimal.equal?(PromUaFormat.parse_money("12.345"), Decimal.new("12345"))
    end

    test "malformed grouping is refused, not guessed" do
      # These used to produce plausible-looking wrong numbers: "1,2,3" -> 12.3
      for junk <- ["1,2,3", "1.5.5", "1,23,45"] do
        assert PromUaFormat.parse_money(junk) == nil, "#{junk} should be refused"
      end
    end

    test "negatives survive" do
      assert Decimal.equal?(PromUaFormat.parse_money("-5,50"), Decimal.new("-5.50"))
    end
  end

  describe "Shopify variant prices use the same parser" do
    # The truncation fix landed on the Prom.ua side only. `OptionBuilder`
    # still matched `{decimal, _}` on Shopify's "Variant Price", so the same
    # feed values imported wrong through the other format — and since
    # `base_price` is the MINIMUM variant price, one mangled row set the
    # price for every variant of the product.

    test "a decimal comma is not truncated into the base price" do
      rows = [
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "12,50"},
        %{"Option1 Name" => "Size", "Option1 Value" => "L", "Variant Price" => "18,00"}
      ]

      base = OptionBuilder.build_from_variants(rows).base_price
      assert Decimal.equal?(base, Decimal.new("12.50")), "base_price was #{base}"
    end

    test "a thousands separator is not truncated into the base price" do
      # Previously imported as 1 — a 1,234.56 product on sale for a euro.
      rows = [%{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "1,234.56"}]

      base = OptionBuilder.build_from_variants(rows).base_price
      assert Decimal.equal?(base, Decimal.new("1234.56")), "base_price was #{base}"
    end

    test "an unreadable variant price is dropped, not treated as free" do
      rows = [
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "abc"},
        %{"Option1 Name" => "Size", "Option1 Value" => "L", "Variant Price" => "18.00"}
      ]

      base = OptionBuilder.build_from_variants(rows).base_price
      assert Decimal.equal?(base, Decimal.new("18.00")), "base_price was #{base}"
    end
  end

  describe "parse_int/2 (malformed payload crashes)" do
    test "returns the default instead of raising" do
      # String.to_integer/1 raised here, and a raise inside handle_event/3
      # takes the socket down — reachable unauthenticated via the storefront
      # quantity field.
      assert Helpers.parse_int("abc", 1) == 1
      assert Helpers.parse_int("", 1) == 1
      assert Helpers.parse_int(nil, 1) == 1
      assert Helpers.parse_int("3abc", 1) == 1
      assert Helpers.parse_int(%{}, 1) == 1
    end

    test "parses genuine integers, including negatives" do
      assert Helpers.parse_int("42", 1) == 42
      assert Helpers.parse_int(" 7 ", 1) == 7
      assert Helpers.parse_int("-3", 1) == -3
      assert Helpers.parse_int(9, 1) == 9
    end
  end

  describe "parse_page/1" do
    test "never returns a non-positive page" do
      assert Helpers.parse_page("0") == 1
      assert Helpers.parse_page("-5") == 1
      assert Helpers.parse_page("abc") == 1
      assert Helpers.parse_page(nil) == 1
      assert Helpers.parse_page("3") == 3
    end
  end
end
