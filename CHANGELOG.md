# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added
- **Cart-activity notifications for shop operators.** Three individually
  toggleable storefront signals — first item added to a cart, every item
  added, and checkout started — delivered through core's notification layer
  (each recipient's own channels: in-app, email, Telegram). New settings card
  under Shop → Settings: per-event toggles plus a recipient list chosen from
  shop administrators (empty list = all admins). Per-cart deduplication is an
  atomic jsonb flag claim, so concurrent tabs cannot double-fire; the
  checkout signal only fires on a connected LiveView mount, so crawlers and
  static renders never claim the flag. All sends are best-effort: a
  notification failure can never break the storefront action. Settings:
  `shop_notify_cart_first_item`, `shop_notify_cart_item`,
  `shop_notify_checkout_started`, `shop_notification_recipients`.
- **Shipping-skip modes.** `shop_shipping_skip_mode` — `off` (legacy hard
  requirement), `fallback` (orders may proceed without a shipping method when
  no active method covers the buyer's country), `always` (shipping step
  disabled). Skipped orders carry `"shipping_skipped" => true` and a
  `"shipping_skip_reason"` in order metadata, add no synthetic shipping line
  item, charge no shipping amount, and suffix the operator's new-order
  notification with "— shipping pending". Server-side conversion re-validates
  the mode independently of the LiveView.
- **Configurable shipping-selection position.** `shop_shipping_selection_position`
  — `cart` (legacy) or `checkout`: the buyer picks a shipping method as a
  checkout step after billing, when the destination country is known, so
  methods are filtered by real country instead of the cart page's
  country-blind list. With `fallback`, an uncovered country collapses the
  step into a localized "we will contact you" notice.
- **Localized shipping-pending notices** (en/ru/et) on the checkout shipping
  step and the order-completion page.

### Fixed
- German titles now slugify with orthographic expansions (`Größe Fußball` →
  `groesse-fussball`, not `gro-e-fu-ball`): ä/ö/ü/ß map to ae/oe/ue/ss before
  core's transliteration pass.
- Operator new-order and cart-activity notifications now show the product's
  real localized title (the previous code matched a nonexistent `:name`
  field and always fell back to "product").
- Orders converted without a shipping method can never inherit a stale
  shipping charge: `calculate_shipping/3` returns 0 when no method is set.
- The billing-less checkout path (authenticated buyer, payment option not
  requiring a billing profile) now routes through the same shipping-step
  decision as every other path instead of jumping straight to review.

## 0.1.16 - 2026-08-08

The storefront-translation, services-vocabulary and price-on-request wave
(PR #16), plus the post-merge review in
`dev_docs/pull_requests/2026/16-storefront-i18n-services-price-on-request/CLAUDE_REVIEW.md`.

Two things a shop operator should know before upgrading. `shop_hide_zero_decimals`
existed in the merged PR but **rounded** every non-round price on the storefront
(40.50 rendered as "41"); it is fixed here and off by default either way. And
"price on request" lines snapshot an amount of `0`, so the cart and order totals
they appear in do not include them — the pages that show a total now say so.

### Added
- **Storefront i18n actually reaches the storefront.** The content language is a
  DIALECT (`ru-RU`, `et-EE`) and this module ships `priv/gettext/{en,ru,et}` —
  plain codes — and Gettext does not fall back between them, so every lookup
  missed and returned its English msgid however complete the catalogues were.
  `Helpers.put_content_locale/1` resolves the dialect against the backend's known
  locales and is called from every public `mount/3`, which runs once per process
  for both the dead render and the connected mount. An unknown locale RESETS to
  the shop's configured default rather than no-opping: the dead render reuses a
  connection process across keep-alive requests, so a no-op served the previous
  visitor's language to the next one.
- **`PhoenixKitEcommerce.Vocabulary`** — `shop_catalog_vocabulary` decides what
  the storefront calls what it sells: `"products"` (default, unchanged for every
  existing install), `"services"`, or `"mixed"` (neutral wording). Each variant is
  a SEPARATE complete `gettext` literal, not a noun swapped into a sentence:
  Russian and Estonian inflect the noun for a case the surrounding sentence
  chooses, so `"No %{noun} available"` cannot be translated for a noun the
  translator never saw.
- **Price on request** — `Product.metadata["_price_display"]["on_request"]`
  suppresses the amount on the storefront while the product keeps the price the
  operator quotes from. Snapshotted onto the cart line and forwarded into the
  order's line items, never read live: `product_uuid` is `ON DELETE SET NULL`, and
  a line agreed as "price on request" must not later render as a number. Written
  only when true, so no existing product gains a key on its next save.
- **`shop_hide_zero_decimals`** — render `40` rather than `40.00` when the
  fractional part is entirely zero. Storefront only; invoices, receipts and credit
  notes keep two decimals, which is the auditable form.
- **One-click product status toggle** in the admin list (active ⇄ draft only —
  leaving `archived` is a deliberate act). Re-reads the row rather than trusting
  the last render, and audits both the success and the failure branch.
- **Translated storefront copy** — 48 new msgids this release, en/ru/et complete.

### Fixed
- **`shop_hide_zero_decimals` misstated prices** (review #1). Trimming is done by
  handing billing a currency copy with `decimal_places: 0`, and
  `Currency.format_amount/2` *rounds* to that precision — so with the setting on,
  `40.50` rendered as "€41", `40.49` as "€40" and `1234.99` as "€1,235", on the
  catalog price, the cart line, shipping, tax and the total. The places are now
  zeroed only for an amount that rounding cannot change, which is the rule the
  plain-code branches already applied.
- **The checkout review step and the product page's "already in cart" notice
  rendered an on-request line as `0.00`** (review #2, #3) — the cart and
  confirmation pages routed through `PriceDisplay`, the two pages between them did
  not, one of them being the last page before the order is placed. All five line
  render sites now share `PriceDisplay.line_on_request?/1`.
- **Cart and order totals no longer imply an on-request line is free** (review
  #7). The amounts are unchanged — they are what billing charges — and the cart,
  checkout, confirmation and order-details pages now disclose that items priced on
  request are not included in the total.
- **~35 untranslated strings on the checkout page**, including the entire billing
  form (`First Name *`, `Country *`, `Select country...`), the step labels,
  `Confirm Order` and the order summary (review #4). Also
  `"Failed to create order. Please try again."`, `"N product(s) found"`, the three
  `admin_edit_label` assigns, and all eight add-to-cart failure toasts, which were
  raw English in the function the PR edited (review #5).
- **The two public order pages translated against core's catalogue** (review #8),
  so the locale this module sets on its own backend never applied to them: `Total`,
  `Status`, `Pending`, `Completed`, `Clear`, `Next` and the `Access denied` flash
  rendered English. They now use the module's backend. Admin pages' core-backend
  labels are untouched — that is core's shared UI vocabulary.
- **"Showing X of Y items" and "N product(s) found" bypassed `Vocabulary`**
  (review #6) — the first had been neutralized to "items" for every shop,
  including a products shop whose heading two lines up says "Products". Both now
  route through `Vocabulary.showing_of/2` and `Vocabulary.count_found/1`.
- **Cyrillic category slugs were stored empty.** `Category.slugify/1` used
  `~r/[^\w\s-]/` without the `u` flag, which matches no Cyrillic, so a Russian-only
  category name was stripped character by character and the category was left with
  no URL. It now uses core's `Slug.slugify(text, transliterate: true)`, the same
  slugifier `Product` was already on. Existing rows regenerate on their next save.
- **The confirmation page no longer promises an email nobody sends** to a
  signed-in customer — the only mail checkout sends is the guest account
  confirmation.
- **Mobile storefront navigation** — categories render as their own nav on the
  catalog and category pages instead of hiding inside a drawer labelled "Filters"
  (and no longer twice on a phone), and the filter button is suppressed when no
  filters are configured rather than opening an empty drawer.
- **Duplicate cart link** removed from the catalog page; the translated
  `storefront_bar` above it already carries one.
- **`compare_at_price` is suppressed for an on-request product** on the catalog
  card and the product page — a struck-through price beside "Price on request" is
  a number the customer was not shown.

## 0.1.15 - 2026-08-06

Dependency-contract release. PR #15 raised the core floor to the release that
actually ships the module the admin lists depend on; the post-merge review
found the sibling billing floor stale in the same way, only wider. Findings in
`dev_docs/pull_requests/2026/15-core-version-floor/CLAUDE_REVIEW.md`.

Nothing about this package's behaviour changed — `mix.lock` already carried
both dependencies well above the new floors. What changed is what a *consumer*
is allowed to resolve.

### Changed
- **`phoenix_kit` floor raised to `~> 1.7.231`** (PR #15). `Web.Products` and
  `Web.Categories` `use PhoenixKitWeb.Live.UrlState`, which first shipped in
  core 1.7.231, while the requirement still named 1.7.214. A consumer whose
  resolution landed below it got a package referencing a module their core
  does not have: a compile failure from source, or an `UndefinedFunctionError`
  on `on_mount/4` the first time an admin opened the products or categories
  list, since the `on_mount({:url_state, cfg})` tuple is baked into the
  `.beam`. Verified by building against both releases — 1.7.230 fails to
  compile, 1.7.231 is clean. The floor now also agrees with
  `@payment_option_version 162`, core's V162 migration having shipped in the
  same release.
- **`phoenix_kit_billing` floor raised to `~> 0.5.2`.** `~> 0.1` admitted
  0.1.0, which predates the `PhoenixKitBilling` namespace entirely (it was
  `PhoenixKit.Modules.Billing`, so every call site here is undefined), and
  0.1.1–0.1.2, which have no tax API. More quietly, `Order.payment_option_uuid`
  — the column `maybe_put_payment_option/2` writes once the host is migrated to
  core V162 — only exists from billing 0.5.2. Below that, `cast/3` drops the
  attr without an error and the order/payment-option linkage vanishes with
  nothing reporting it.

### Added
- `test/phoenix_kit_ecommerce/dependency_floor_test.exs` — DB-free contract
  test pinning the symbols the two floors exist to guarantee (`UrlState`,
  `Migrations.Postgres.migrated_version_runtime/1`,
  `Order.payment_option_uuid`, the billing tax trio). It asserts against the
  resolved dependency, so it fails in any build where resolution lands below a
  floor — the case this workspace's always-latest `mix.lock` can never
  reproduce, which is why both defects had to be found by reading.

## 0.1.14 - 2026-08-05

The storefront layout, price-unit and permission wave (PR #13) and URL-backed
admin list state (PR #14), plus the post-merge reviews in
`dev_docs/pull_requests/2026/13-storefront-layout-price-units-permissions/`
and `dev_docs/pull_requests/2026/14-url-state-search/`.

⚠️ **Breaking on upgrade — authorization.** The `"shop"` permission is now
admin-area READ access, with four sub-permissions carrying the capabilities
(`shop.manage_catalog`, `shop.manage_carts`, `shop.manage_settings`,
`shop.run_imports`). Core auto-grants newly discovered sub-permissions to the
**Admin system role only**, so a CUSTOM role holding base `"shop"` keeps its
reads but loses every mutation until an operator re-grants. Secure by default
and deliberate, but it needs an operator action.

### Added
- **The storefront renders in the HOST's layout.** Every public page — catalog,
  category, product, cart, checkout, confirmation — now goes through core's
  `LayoutWrapper.app_layout` for guests and logged-in visitors alike. It used
  to dispatch three ways, including a module-owned layout that bypassed the
  host entirely (the reported bug) and the ADMIN dashboard layout for any
  authenticated shopper. The category/filter sidebar the dashboard layout
  carried now renders in the page templates for everyone, and a compact
  in-content Shop/Cart bar covers hosts whose own header has no cart link
  (`shop_show_cart_bar`, default on).
- **`PhoenixKitEcommerce.PriceDisplay`** — an optional per-language price unit
  ("per hour", "/m²", "в час") and "From" prefix, stored under one reserved
  `Product.metadata["_price_display"]` namespace, no migration. `render/4`
  takes an explicit context: `:catalog` may show "From", while `:selected`,
  `:cart` and `:order` are exact and render the SNAPSHOTTED unit, so editing or
  deleting a product cannot relabel a line a customer already agreed to. The
  unit rides into the order's line items and reaches billing's invoices.
- **Four shop sub-permissions** with `PhoenixKitEcommerce.Web.Authz`: admin
  tabs carry their key so the sidebar hides what a holder cannot use, and 48
  mutating event handlers re-check, failing closed on a missing scope.
- **Notifications** for order placement (admins), order confirmation (the
  customer, separately muteable) and import completion/failure. Recipients
  union permission holders with Owner-role holders and `"*"` superadmins,
  neither of which has permission rows.
- **URL-backed list state** on the Products and Categories admin lists (PR
  #14): search, filters and page live in the query string, so a filtered list
  is a shareable, reload-proof URL and Back returns to the previous query. The
  list load also moved out of `mount/3`, which runs twice.

### Fixed
- **Money on the checkout review screen.** Two paths reached `:review` without
  pricing the cart, and a cart broadcast from another tab was assigned into an
  open review, dropping the country and its tax — so the total shown could
  differ from the total charged.
- **The cheapest shipping method was not always the cheapest.** `Enum.min_by`
  over `%Decimal{}` compares by Erlang term order, so `9.99` sorted above `10`
  and cart mount could auto-select the dearer method.
- **Shipping eligibility was judged on total weight** while listing and pricing
  used shippable weight, so a mixed cart was quoted a method and then refused
  at checkout. `requires_shipping` is no longer decorative: digital-only carts
  are neither forced through shipping selection nor charged for it.
- **The advertised price range under-quoted.** Map-shaped override modifiers
  were skipped though the charged path parses them ("From $20" for an item that
  charges $30), and an offered option value with no modifier entry was skipped
  instead of contributing a zero delta, so a product whose cheapest option is
  free advertised its most expensive combination.
- **Order history could be rewritten** — order pages preferred the LIVE billing
  profile over the order's snapshot. Cart, checkout and order pages also
  rendered today's default currency instead of the amount's own.
- **The price unit was rendered against the line TOTAL** on the order
  confirmation and order-details pages, so a line of 2 hours at €40.00 per hour
  read "€80.00 per hour". Both pages now render the total plain with the unit
  price beside it, matching the cart page.
- **A disabled shop stayed fully browsable and purchasable.**
- **Products could be bought after being deactivated** — the conversion check
  now runs on locked rows inside the transaction. `body_html` (where imports
  put the full supplier description) is now rendered on the public product
  page, under the same sanitization policy as `description`.
- **Blank-address orders**, now validated in the CONTEXT for both billing
  paths, and the selected payment option is no longer discarded at conversion.
- **Imports: a re-import deleted what the feed said nothing about.** An omitted
  column arrives as a blank, and that blank overwrote the stored value —
  erasing descriptions in every language, images, vendor, and the admin's own
  price modifiers, image mappings and custom metadata. Also: slug lookup
  normalized `"en"` to `"en-US"` while every writer stores the shop's code
  verbatim (404s and failed re-matches on a base-code shop); a Cyrillic title
  slugified to an empty string, so a Ukrainian catalogue re-imported itself
  every run; a variant set with no readable price published a FREE product
  instead of failing; and rows with a blank handle all grouped together, so
  unrelated products merged into one.
- **A malformed `?category=` or `?parent=` crashed the admin list LiveViews.**
  Both reach Ecto as UUID query parameters, where a non-UUID raises
  `Ecto.Query.CastError`; they now fall back to an unfiltered list.
- **Import-failure notifications went missing on non-ASCII catalogues.** The
  reason string was truncated on bytes, splitting UTF-8 mid-character into a
  value Postgres rejects — and the best-effort wrapper then swallowed it.

### Changed
- Stale `mix.lock` entries left by the preceding dependency upgrade (igniter,
  sourceror, spitfire, rewrite, owl, ex_ast, glob_ex, text_diff) pruned, which
  unblocks `mix precommit`.

## 0.1.13 - 2026-08-04

Checkout security and wrong-money fixes (PR #12), plus the post-merge review
in `dev_docs/pull_requests/2026/12-checkout-security-policy-settings/`.
0.1.12 was tagged but never published, so its changes ship here too.

### Added
- **`PhoenixKitEcommerce.Policy`** — seven admin-controllable policy keys behind
  one module, so the settings UI and the enforcement points cannot disagree
  about a default. Every key ships in its safe position and every reader fails
  **closed** on a settings-layer error: `shop_order_lookup_policy`,
  `shop_allow_raw_html_descriptions`, `shop_allow_svg_uploads`,
  `shop_image_import_allow_private_networks`, `shop_default_tax_country`,
  `shop_import_cleanup_scope`, `shop_legacy_cookie_until`. Genuine invariants
  deliberately get no setting. All policy changes are activity-logged.
- **`css_sources/0`** — documented in the README since forever, never
  implemented, so Tailwind purged every class used only by this module's
  templates from the host build. The absence was masked whenever any other
  PhoenixKit module was installed.
- **`PhoenixKitEcommerce.Import.Money`** — one supplier-money parser shared by
  every import format.
- First test suites for `Options` pricing, the import money parser, the
  security regressions, guest order access, and the admin-permission contract.

### Fixed
- **Billing-profile IDOR.** `select_profile` accepted any client-supplied uuid
  and order creation copied that profile's name, address, phone and email onto
  the attacker's order. Now checked at selection, at `confirm_order`, and again
  in the context — `convert_cart_to_order/2` is public and re-exported, so it
  must not depend on one caller remembering.
- **Order confirmation pages were world-readable.** Access was granted for any
  order with a nil `user_uuid` and for any order whose owner was unconfirmed —
  and guest checkout creates exactly such users. Orders now record the placing
  shop session, with a `cart_uuid → cart.session_id` fallback so pre-existing
  guest orders keep working.
- **Cart takeover on a shared browser.** The logged-in fallback matched carts by
  `session_id` without the `is_nil(user_uuid)` guard, and the cookie outlives
  logout by 30 days. The cookie is now signed, `SameSite=Lax`, Secure-on-HTTPS,
  with a narrow one-time migration for pre-signing cookies.
- **Stored XSS on the storefront** via `sanitize={false}` and a bare `raw/1`.
- **SSRF in the CSV image importer**, three ways: redirects were never
  re-validated, IPv4-mapped IPv6 bypassed the private-range check entirely
  (`::ffff:127.0.0.1` read as public), and no guard existed before that.
  Post-merge: both address families are now resolved, so an IPv6-only image
  host is no longer blocked outright and a public-A/private-AAAA host no longer
  slips through.
- **Draft, inactive and archived products were public and purchasable**, via two
  separate paths.
- **Tax was zero on every order** — the cart page leaves `shipping_country` nil
  and checkout never set it. Fixing that surfaced two more: tax was charged on
  the whole subtotal while `CartItem` carries a `taxable` flag, and the review
  screen showed a pre-tax total while conversion charged tax.
- **Percentage discounts did nothing** — the percent branch was gated on
  `compare(sum, 0) == :gt`, so a negative percent was silently discarded.
  **Price ranges came out inverted** (`Enum.min/max` compare `%Decimal{}` by
  Erlang term order, not value). **Fixed-only prices were never rounded.**
  Post-merge: all three also affected `get_price_range/3` — the storefront's
  "From $X" — which kept its own copy of the arithmetic. Both functions now
  share one helper.
- **CSV prices were silently wrong** — `"12,50"` imported as 12, and the first
  hardening multiplied `"1.2345"` by 10,000. Post-merge: the Shopify
  `"Variant Price"` path still truncated the same way, and since `base_price` is
  the minimum variant price, one mangled row priced every variant.
- **An unreadable price became free stock** — the parser returned nil and the
  call site turned it into `Decimal.new(0)`. The row now fails validation.
- **Free shipping** via a method the cart had outgrown; **lost cart totals**
  under concurrency; **cart edits could commit after the order was created**.
- Confirmation email moved outside the conversion transaction, so an SMTP
  failure can no longer roll back a paid order.
- Import cleanup no longer deletes every empty category in the catalog.
- Five LiveViews had no `handle_info` catch-all; malformed `phx-value-*`
  payloads crashed sockets through `String.to_integer/1`.
- Guest carts orphaned by a fabricated session id on the cross-language
  product path.

### Changed
- Category admin actions re-check `Scope.has_module_access?(scope, "shop")`
  rather than `can_access_admin_area?/1`, which is true for any permission
  holder.
- 25 new strings extracted and translated into ru and et.
- Docs: the Settings Keys sections in `README.md` and `AGENTS.md` listed four
  unprefixed keys the code never read.

## 0.1.12 - 2026-07-27

### Changed
- **Stop calling the deprecated `PhoenixKit.Users.Auth.Scope.admin?/1`.** All 4
  call sites (`Web.Categories`) now call `Scope.can_access_admin_area?/1`, the
  name core renamed it to in phoenix_kit 1.7.214. The old name is a pure
  `@deprecated` delegate, so **no behavior change** — this only silences the
  deprecation warning host apps were eating on every compile of this library,
  with no way to fix it themselves.
- **Dependency floor raised to `phoenix_kit ~> 1.7.214`** (from `~> 1.7.189`) —
  `can_access_admin_area?/1` does not exist below it, so an older core would be
  an `UndefinedFunctionError` at call time rather than a warning. This was not
  hypothetical: the lockfile was resolving 1.7.194.
- Dependency lockfile bumps: `phoenix_kit` 1.7.194 → 1.7.216, `phoenix_live_view`
  1.2.7 → 1.2.8, `beamlab_ex_aws_sqs` 4.0.0 → 5.0.0, `beamlab_countries` 1.0.8 →
  1.1.0, `fresco` 0.8.0 → 0.10.0, `etcher` 0.7.2 → 0.9.0, `ex_ast` 0.12.10 →
  0.13.1, `elixir_make` 0.9.0 → 0.10.0, `mdex` 0.13.3 → 0.13.4, `mdex_native`
  0.2.5 → 0.2.6, `hackney` 4.5.2 → 4.6.0, `req` 0.6.2 → 0.6.3, `tessera` 0.3.2 →
  0.3.4, `bandit` 1.12.0 → 1.12.4, `igniter` 0.8.2 → 0.8.3, `leaf` 0.3.0 → 0.3.2,
  plus `plug_crypto`, `mint`, `quic`, `lazy_html`, `glob_ex`, `earmark_parser`.

## 0.1.11 - 2026-07-16

### Added
- **Admin i18n wave.** All 12 admin LiveViews (carts, categories, category
  form, dashboard, import show, imports, product detail, product form,
  products, settings, shipping method form, shipping methods) are now
  fully gettext-wrapped, using the module-owned `PhoenixKitEcommerce.Gettext`
  backend consistently (replacing leftover `PhoenixKitWeb.Gettext` calls).
  The `ru`/`et` catalogs were extended from 483 to 2,500+ msgids.

### Fixed
- **Gaps in the i18n wave above, found in post-merge review.** The
  product-form Translations tab (title/slug/description/SEO field labels
  and placeholders), several product-form help strings, the products-list
  empty state, the CSV-import confirm-step summary, an import-details
  notice, and a category-option delete confirmation were left unwrapped
  and rendered in English regardless of locale — not caught by
  `mix gettext.extract --check-up-to-date`, since that check only verifies
  already-wrapped calls, not coverage. All wrapped and translated
  (en/ru/et).
- **Cart and shipping-method page-header counts pluralize correctly.**
  `carts.ex` and `shipping_methods.ex` used plain `gettext` for their
  "%{count} ... total/configured" headers instead of `ngettext`, so the
  Russian translation hardcoded a genitive-plural noun regardless of
  count — rendering "1 корзин всего" / "1 методов настроено" at
  `count = 1`. Converted to `ngettext`, matching the categories/products
  pattern, with correct 3-form ru and 2-form et translations.
- Corrected 12 catalog entries gettext's fuzzy-matcher mis-filled from an
  unrelated adjacent label while merging the strings above (e.g. "No
  products found" pre-filled with the Russian/Estonian translation of "No
  categories found").

See `dev_docs/pull_requests/2026/11-admin-i18n-wave/CLAUDE_REVIEW.md` for
the full review.

## 0.1.10 - 2026-07-12

### Fixed
- **Search terms are escaped before hitting ILIKE.** User input flowed
  into the `%term%` pattern raw, so `%`/`_`/`\` acted as wildcards on a
  route open to unauthenticated visitors: searching `100%` matched every
  product containing "100", an SKU search for `AB_100` also matched
  `ABX100`, and a term ending in `\` silently corrupted the pattern into
  requiring a literal `%`. Terms are now length-capped (100 chars),
  NUL-stripped (a crafted `%00` raised `Postgrex.Error`), and
  LIKE-escaped in one choke point (`search_like_pattern/1`) shared by the
  product, category, and admin-cart search filters. The cap also closes a
  cheap unauthenticated seq-scan amplifier (unbounded multi-KB patterns
  against six ILIKE evaluations per row, two of them `jsonb_each_text`
  expansions).
- **Category pages now show a filters-aware zero-result state.** With an
  active search (or price/vendor filter) matching nothing, the category
  page claimed "No products in this category — check back soon" even
  though the category has products; it now says the filters matched
  nothing and offers a clear-filters affordance, matching the main
  catalog page. Both the guest and authenticated layouts share one
  `category_empty_state` component now.
- Documented (code comment) the cross-release ordering limitation of
  `merge_missing_builtin_filters/1`'s below-minimum positioning scheme:
  it holds within one merge pass; a hypothetical second sidebar-leading
  built-in added in a future release should renormalize positions on
  save instead of extending the scheme.

## 0.1.9 - 2026-07-11

### Added
- **Storefront product search.** A new built-in `search` filter type lets
  customers search the public catalog (main page and category pages) by
  product name, description, SKU (`metadata->>'sku'`), and tags — matching
  in any configured language. Renders as a search box at the top of the
  storefront filter sidebar, driven by a `?search=` URL param so results
  are shareable and survive navigation. Enabled by default for new
  installs; existing installs discover it on the Settings page (merged in
  disabled via `merge_missing_builtin_filters/1`) and enable it with one
  toggle.
- Context: `list_products/1` `:search` now also matches SKU and tags
  (previously title/description only), so admin product search finds
  products by article number too.

### Fixed
- **Storefront search no longer raises `ambiguous_column`.** The `:search`
  SQL fragment referenced unqualified `title`/`description` columns, which
  turn ambiguous the moment `:exclude_hidden_categories` joins the
  categories table — the exact combination every public catalog query
  uses. Columns are now bound through the product binding. Pinned by a
  regression test.
- **`merge_missing_builtin_filters/1` no longer collides positions.** A
  saved config from before `search` existed can already hold another
  filter at the same default position (e.g. `price` at `0`); the merged-in
  filter now sorts strictly below every saved filter's position instead of
  reusing its default position outright, so it renders first once enabled
  as intended, even on upgraded installs.

## 0.1.8 - 2026-06-08

### Added
- Developer tooling: `pk_dep/3` in `mix.exs` resolves any `phoenix_kit*` dependency from a local checkout when `<APP>_PATH` is exported (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`), for cross-repo development. Unset — the default — keeps the published Hex pin, so `mix hex.publish` and CI resolve exactly as before. A set-but-blank value (`PHOENIX_KIT_PATH=`) is also treated as unset rather than producing a broken `path: ""` dep. Documented in `AGENTS.md`.

### Changed
- Refresh dependency lock: `phoenix_kit` 1.7.131 → 1.7.133 and `phoenix_kit_billing` 0.4.0 → 0.5.0, plus transitive bumps (`bandit` 1.11.1 → 1.12.0, `etcher` 0.6.5 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `req` 0.5.18 → 0.6.1, `spitfire` 0.3.12 → 0.3.13, `tesla` 1.18.3 → 1.20.0). Declared dependency requirements are unchanged; no library or migration code changed.

## 0.1.7 - 2026-06-05

### Changed
- Migrate the category and product admin forms to core form components. Non-translatable scalar fields (status, product_type, vendor, price/compare_at/cost, position) and the changeset-backed selects (`parent_uuid`, `featured_product_uuid`, `category_uuid`) now render through core `<.input>`/`<.select>`. An `assign_form/2` helper keeps `:changeset` (consumed by the multilang `TranslationTabs` fields) and `:form = to_form(changeset)` in sync, so inline validation errors render on `validate`. Translatable fields, dynamic-option selects, and the option/media machinery are intentionally left as-is.
- Route web body strings through the module's own `PhoenixKitEcommerce.Gettext` backend (was the parent app's `PhoenixKitWeb.Gettext`). Generic UI-chrome strings are still resolved against core to keep its vetted translations; shop-domain strings resolve in-module and ship `et`/`ru` catalogues (correct 2-form/3-form plurals).

### Fixed
- Inline validation errors now render on the migrated `<.select>` fields, via the `phoenix_kit` 1.7.131 core `Select` component (it now maps `field.errors` like `<.input>` does).

### Dependencies
- Bump `phoenix_kit` 1.7.130 → 1.7.131 (core `<.select>` surfaces `field.errors`) and `etcher` 0.5.5 → 0.6.5.

## 0.1.6 - 2026-06-04

### Fixed
- Order `tax_rate` persisted as `0` on cart→order conversion. `build_order_attrs/3` hardcoded a `0` rate while `tax_amount` was computed from the live rate, so every order recorded a 0% rate — breaking receipts, tax reports, and refund math that derive the percentage from the order. Now uses `get_tax_rate(cart)` (single source of truth). Pinned by an end-to-end regression test.
- `unique_constraint` names for `ShippingMethod` (`:slug`) and `ImportConfig` (`:name`, `:uuid`) did not match the actual DB indexes, so duplicate inserts raised `Ecto.ConstraintError` instead of returning `{:error, changeset}`. Pinned to the real index names.
- No-billing tax fallback applied the configured `billing_default_tax_rate` even when `billing_tax_enabled` was `false`; now gated on the enabled flag, matching the `PhoenixKitBilling`-loaded path.
- `DialectMapper.resolve_dialect/2` → `/1` after the `phoenix_kit` upgrade dropped the 2-arity form, restoring a clean `--warnings-as-errors` build.

### Added
- `PhoenixKitEcommerce.Activity` — PII-safe LiveView-layer activity-logging wrapper around `PhoenixKit.Activity`. Logs admin mutations (products incl. bulk, categories, shipping methods, import configs/runs) and never crashes the caller (no-ops when core's `PhoenixKit.Activity` is absent; rescues DB errors).
- `PhoenixKitEcommerce.Errors` — central gettext-backed mapping from error atoms to user-facing strings (`PhoenixKitEcommerce.Gettext` backend). Wired into the `:cart_not_active` and `:unknown_format` paths.
- Test harness: `DataCase`/`LiveCase`, test endpoint/router/layouts, schema via `PhoenixKit.Migration.ensure_current/2`, and full schema/context/LiveView coverage (6 → 183 tests).

### Changed
- Cap `include_keywords`/`exclude_keywords`/`exclude_phrases` import filters at 100 entries each with a friendly changeset error (was unbounded).
- Centralize the nil-currency `$` fallback as a single documented module attribute.
- Migrate the shipping-method form to core components (`<.input>`/`<.select>`/`<.textarea>` with `assign_form/2`) for inline validation errors.
- Log a warning on `billing_default_tax_rate` parse failure instead of silently falling back to `0`.
- Refresh `mix.lock` for the upgraded `phoenix_kit` and related dependencies.

## 0.1.5 - 2026-05-09

### Fixed
- Mark `PhoenixKit.Modules.Shop` compat module as `@moduledoc false` to silence ex_doc warnings about `defdelegate` pointing at hidden `@impl PhoenixKit.Module` callbacks. Docs-only change; no behavioural difference.

### Added
- Broaden i18n test coverage to iterate `admin_tabs/0 ++ settings_tabs/0 ++ user_dashboard_tabs/0` (was admin-only). Add direct `Gettext.gettext(EcommerceGettext, ...)` assertions independent of `Tab.localized_label/1`.

## 0.1.4 - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKitEcommerce.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

## 0.1.3 - 2026-04-06

### Added
- Add `version/0` callback to display package version on modules page

### Changed
- Remove deprecated `select-bordered` class for daisyUI 5 compatibility
- Expand compat module with full delegation list
- Add `elixirc_options: [ignore_module_conflict: true]` for umbrella compatibility

### Fixed
- Fix compilation errors after core changes

## 0.1.2 - 2026-03-30

### Added

- Compat alias modules (`lib/phoenix_kit_ecommerce/compat/`) bridging old `PhoenixKit.Modules.Shop.*` namespace to `PhoenixKitEcommerce.*` for backward compatibility
- Billing module as single source of truth for tax rates with Settings fallback

### Changed

- Remove explicit `LayoutWrapper.app_layout` from 14 admin LiveViews (core now auto-applies admin layout; kept in `shop_layouts.ex` for public storefront)
- Convert 5 admin list pages (carts, categories, products, shipping methods, import configs) to `table_default` + `table_row_menu` components
- Remove 65 duplicate files from old `lib/phoenix_kit/modules/shop/` namespace and 2 duplicate mix tasks

### Fixed

- Add admin authorization check (`Scope.admin?/1`) to individual category delete, matching bulk operations
- Replace raw `<tr><td>` empty-state rows with proper `table_default` components in shipping methods and import configs
- Fix weight formatting in shipping methods to use `Float.round/2` for precision consistency with carts

## 0.1.1 - 2026-03-29

### Changed

- Restructure from `lib/phoenix_kit/modules/shop/` to `lib/phoenix_kit_ecommerce/` matching standard extracted-repo convention
- Rename all modules from `PhoenixKit.Modules.Shop.*` to `PhoenixKitEcommerce.*`
- Update billing references from `PhoenixKit.Modules.Billing.*` to `PhoenixKitBilling.*`
- Move mix tasks to `lib/phoenix_kit_ecommerce/mix_tasks/`
- Add `:mix` to dialyzer PLT apps for clean dialyzer runs

### Fixed

- Fix 33 nesting depth violations (max depth 2) by extracting helper functions and using `with` chains
- Fix 11 cyclomatic complexity violations (max 9) by splitting large functions into multi-clause helpers
- Fix 25 alias ordering issues across all modules
- Fix dead code in `get_mapped_image/4` where `|| current_image` could never trigger
- Add `elixirc_paths/1`, `aliases/0` (quality/precommit) to mix.exs matching sibling conventions

### Added

- Comprehensive README with features, installation, usage examples, architecture, and troubleshooting
- AGENTS.md for AI agent guidance
- CHANGELOG.md for release tracking
- MIT LICENSE file

## 0.1.0 - 2026-03-29

### Added

- Initial e-commerce module with PhoenixKit.Module behaviour
- Product catalog with physical and digital product support
- Multi-language content (titles, slugs, descriptions, SEO fields)
- Hierarchical categories with nesting and per-category option schemas
- Dynamic product options with fixed and percentage price modifiers
- Shopping cart with guest (session-based) and user (persistent) modes
- Cart real-time sync across tabs via PubSub
- Checkout flow with PhoenixKitBilling integration for order conversion
- Shipping methods with weight/price constraints and geographic restrictions
- CSV import system with automatic format detection (Shopify, Prom.ua, generic)
- Oban workers for async CSV imports and image migration
- Admin dashboard with product, category, shipping, cart, and import management
- Public storefront pages (catalog, category, product detail, cart, checkout)
- User order history and order detail pages
- Import configuration profiles with keyword filtering and category rules
- Product deduplication mix task
