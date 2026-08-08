defmodule PhoenixKitEcommerce.Policy do
  @moduledoc """
  Admin-controllable policy for the shop, in one place.

  These are the knobs where a shop owner can legitimately want either
  behaviour. Everything here is **secure by default** — the default value
  is the safe one, and relaxing it is an explicit, logged admin decision
  made on the E-Commerce settings page.

  Genuine invariants are NOT here. "Only the owner of a billing profile
  may attach it to an order" is not a preference, so it has no setting;
  it is simply enforced.

  ## Keys

  | Setting | Default | Effect of the default |
  |---|---|---|
  | `shop_order_lookup_policy` | `"strict"` | An order confirmation page requires the session that placed it |
  | `shop_allow_raw_html_descriptions` | `"false"` | Product descriptions are HTML-sanitized before rendering |
  | `shop_image_import_allow_private_networks` | `"false"` | CSV image import refuses loopback/private/link-local hosts |
  | `shop_allow_svg_uploads` | `"false"` | SVG is rejected by the image importer |
  | `shop_default_tax_country` | `""` | No fallback country; tax uses the address actually collected |
  | `shop_import_cleanup_scope` | `"auto_created"` | Import cleanup only removes categories that import created |

  Each reader tolerates a missing or malformed stored value by falling
  back to the safe default rather than raising — a settings row that has
  been hand-edited to nonsense must not take the storefront down, and
  must not silently mean "permissive".
  """

  alias PhoenixKit.Settings

  @doc """
  How `/checkout/complete/:uuid` decides whether a visitor may see an order.

  * `:strict` (default) — the visitor must own the order, or hold the shop
    session that placed it. A bare UUID is not enough.
  * `:link` — knowing the UUID is enough. Only appropriate for a shop that
    deliberately mails "view your order" links and accepts that the URL is
    the credential: order URLs leak through Referer headers, browser
    history, and forwarded mail.

  The old behaviour was `:link` for every guest order, without anyone
  choosing it — and because guest checkout creates unconfirmed users, that
  also covered every order belonging to a registered-but-unconfirmed user.
  """
  @spec order_lookup_policy() :: :strict | :link
  def order_lookup_policy do
    case read("shop_order_lookup_policy", "strict") do
      "link" -> :link
      _ -> :strict
    end
  end

  @doc """
  Whether product descriptions may contain raw, unsanitized HTML.

  Defaults to `false`. When false the storefront and admin previews run
  descriptions through the core HTML sanitizer.

  Turning this on trusts **everyone who can write a product description**
  with script execution in every shopper's browser — including the Owner's.
  That is a wider blast radius than it looks: descriptions are also
  populated by CSV import, so it extends trust to whoever supplies the
  import file.
  """
  @spec allow_raw_html_descriptions?() :: boolean()
  def allow_raw_html_descriptions?, do: read_boolean("shop_allow_raw_html_descriptions", false)

  @doc """
  Whether the CSV image importer may fetch from private network ranges.

  Defaults to `false`, which blocks loopback, private, link-local and
  cloud metadata addresses. With it on, an admin-supplied CSV can make the
  server fetch internal URLs and store the response — a working port
  scanner and metadata-credential reader. Only enable it when importing
  from a genuinely internal, trusted image host.
  """
  @spec image_import_allow_private_networks?() :: boolean()
  def image_import_allow_private_networks?,
    do: read_boolean("shop_image_import_allow_private_networks", false)

  @doc """
  Whether SVG is accepted by the image importer.

  Defaults to `false`. Stored files are served inline with their stored
  MIME type, and an SVG can carry script — so an accepted SVG is a stored
  XSS channel independent of the description sanitizer.
  """
  @spec allow_svg_uploads?() :: boolean()
  def allow_svg_uploads?, do: read_boolean("shop_allow_svg_uploads", false)

  @doc """
  Optional fallback country code used for tax when the cart has no
  shipping or billing country yet.

  Returns `nil` when unset (the default), meaning tax is computed only
  from an address actually collected at checkout. Set it to e.g. `"EE"` if
  your shop is single-jurisdiction and should charge tax even before the
  customer supplies an address.
  """
  @spec default_tax_country() :: String.t() | nil
  def default_tax_country do
    case read("shop_default_tax_country", "") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          country -> String.upcase(country)
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether pre-signing shop-session cookies may still be adopted.

  When the cookie became signed, every existing unsigned one stopped
  verifying — so without a migration each guest silently lost their cart
  on upgrade. `PhoenixKitEcommerce.Web.Plugs.ShopSession` therefore adopts
  a legacy cookie once and re-issues it signed.

  That path is a standing weakness: an unsigned value is replayable by
  anyone who obtained it out-of-band, so it must not outlive the upgrade
  it exists for. Set `shop_legacy_cookie_until` to an ISO8601 date (or
  datetime) to close the window; after it passes, unsigned cookies are
  refused outright and those visitors simply get a fresh cart.

  Default: `nil`, meaning "still migrating". That is the compatible
  default rather than the strict one — a shop that upgrades without
  reading release notes must not lose customer carts — but it is the one
  setting here where leaving the default forever is the wrong choice.
  Adopted ids never authorize an order regardless of this setting.
  """
  # `now` is a DateTime, not a Date: `parse_cutoff/2` compares with
  # `DateTime.compare/2`, which raises on a `Date`. The spec said
  # `Date.t() | DateTime.t()` and advertised an argument that would crash
  # the plug that calls this.
  @spec legacy_cookie_window_open?(DateTime.t()) :: boolean()
  def legacy_cookie_window_open?(now \\ DateTime.utc_now()) do
    case read("shop_legacy_cookie_until", "") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> true
          cutoff -> parse_cutoff(cutoff, now)
        end

      _ ->
        true
    end
  end

  defp parse_cutoff(cutoff, now) do
    parsed =
      case DateTime.from_iso8601(cutoff) do
        {:ok, dt, _} -> {:ok, dt}
        _ -> date_cutoff(cutoff)
      end

    case parsed do
      {:ok, dt} -> DateTime.compare(now, dt) == :lt
      # An unparseable cutoff is a configuration error. Fail OPEN here: the
      # alternative silently drops every guest's cart on a typo, and the
      # adopted id cannot authorize an order in any case.
      :error -> true
    end
  end

  defp date_cutoff(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> DateTime.new(date, ~T[00:00:00], "Etc/UTC")
      _ -> :error
    end
  end

  @doc """
  Which categories the post-import cleanup step may delete.

  * `:auto_created` (default) — only categories that the import itself
    created and left empty.
  * `:all_empty` — every empty category in the catalog. This is what the
    code used to do regardless of the UI's promise, and it destroys
    deliberately-empty categories such as a "Coming Soon" placeholder.
  """
  @spec import_cleanup_scope() :: :auto_created | :all_empty
  def import_cleanup_scope do
    case read("shop_import_cleanup_scope", "auto_created") do
      "all_empty" -> :all_empty
      _ -> :auto_created
    end
  end

  # Settings reads are ETS-cached but can still fail on a cache miss with
  # an unreachable database. Fail to the SAFE default, never to permissive.
  defp read(key, default) do
    Settings.get_setting_cached(key, default)
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp read_boolean(key, default) do
    read(key, to_string(default)) == "true"
  end
end
