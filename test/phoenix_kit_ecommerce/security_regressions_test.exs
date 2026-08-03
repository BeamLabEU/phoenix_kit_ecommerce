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
