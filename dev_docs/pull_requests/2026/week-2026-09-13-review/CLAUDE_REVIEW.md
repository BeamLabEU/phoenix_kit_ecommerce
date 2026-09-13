# Code Review: week of 2026-09-07 → 2026-09-13 (0.5.0 – 0.5.3)

**Reviewed:** 2026-09-13
**Reviewer:** Claude (Fable 5.1), five parallel read-only reviewers by area,
findings verified against the tree before any fix was applied.
**Scope:** every commit on `main` since `c712a68` (PR #33), i.e. PRs
#32–#55 plus the three post-merge review commits and the four "lib
upgrades" commits — 31 commits, ~33k lines added. Reviewed as the current
tree, not PR-by-PR.
**Status:** Fixed on `main` in the commit that carries this document,
except where a finding is marked *left open*.

## Summary

The week delivered four large features (per-domain currency Э1–Э3, the
catalogue product source, Shopify media/variants/collections sync, and the
storefront/admin UI work around them). The invariants held: money is
`Decimal` everywhere, every public LiveView calls `put_content_locale/1`,
every mutating admin event re-checks its capability, add-to-cart trusts no
client-supplied price or currency, the image importer's redirect
re-validation and IP-literal parsing are correct, and the catalogue source
still fails closed when the package is absent.

The problems were, again, at the seams between features: a cart frozen
against the OLD base currency silently mis-pricing every line added after a
base change; shipping methods listed in the cart's currency symbol with
base-currency numbers; a crafted query string that 500s every storefront
page; a Markdown converter that re-materialised escaped `<script>`; DNS
rebinding around the SSRF guard; and an entities-side requirement (a
creator on every attribute set) that the Shopify variants sync never met, so
every set creation fails against the current catalogue.

Two infrastructure findings matter to hosts: the core floor was one minor
too low (the columns it guarantees ship in 2.16.0, not 2.15), and the test
harness never applied the catalogue migration chain, so the 136
`:catalogue`-tagged tests — the only coverage for the catalogue adapter,
the writer and the media worker — had been failing on setup, not on code.

## Findings

Severity scale: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`,
`NITPICK`.

### Per-domain currency (Э1–Э3, #33 #38 #39 #47 #55)

| # | Severity | Finding | Resolution |
|---|---|---|---|
| C1 | BUG - HIGH | An open cart keeps its frozen `base_currency` after `change_base_currency/2`; `snapshot_unit_price/2` then stores a NEW-base `base_unit_price` into an OLD-base cart (unconverted for a same-currency cart, double-converted for a foreign one), and `refresh_cart_rate/1` / `cart_rate_drift/1` re-derive from the mixed base and make it worse. | New public `rebase_cart/1`: locks and reloads the cart, derives the multiplier from the old base's renormalised row (`1 / exchange_rate`), multiplies every line's `base_unit_price`, inverts and re-multiplies `compare_at_price`, re-snapshots both at the cart currency's current effective rate, rewrites `base_currency`/`exchange_rate`, recalculates totals. Run by both `add_to_cart/4` clauses, `refresh_cart_rate/1`, `merge_guest_cart/2` and `convert_cart_to_order/2`; `cart_rate_drift/1` reports nothing for a stale cart. New errors `:cart_base_unavailable`, `:currency_unavailable`. `cart_rebase_test.exs` (8 tests). |
| C2 | BUG - HIGH | Cart and checkout templates rendered `method.price` (a base-currency authoring amount) with the cart's currency symbol, and `free_for?/2` compared a display-currency subtotal against a base threshold — the list said "€10.00" for a $10 method that charges €9.09. | New `present_shipping_method/2` (`%{price:, free?:}` through `from_base/2`/`to_base/2`) used by both templates. `cart_page_shipping_fx_test.exs`. |
| C3 | BUG - MEDIUM | `reprice_products_for_base_change/4` went through `update_product/2`, which broadcasts `product_updated` per row from INSIDE billing's transaction, before commit. Docs still claimed this tree has no `ProductSource`. | Direct `Product.changeset` + `repo().update()` keeping `normalize_product_attrs/1`; billing's post-commit `currencies_changed` is the signal the pages already answer. Moduledoc and test header corrected; the doc now says hosts must pass this function as `:reprice` and that the catalogue source is refused. |
| C4 | IMPROVEMENT - MEDIUM | Three storefront pages re-ran the full product query on every `{:currencies_changed, code}`; billing broadcasts once per currency per refresh. | `Helpers.schedule_fx_reload/2`: the cheap currency re-mark stays immediate, the product re-fetch is coalesced behind one 250 ms timer. |
| C5 | BUG - MEDIUM | `validate_catalogue_products_active/1` read one catalogue item per distinct line inside the conversion transaction. | One `list_products_by_ids/1` call. |
| C6 | BUG - MEDIUM | Guest→user merge copied `unit_price` verbatim when currencies matched even if the two frozen rates differed. | Restamp from base unless currency AND rate are equal. |
| C7 | BUG - MEDIUM | `refresh_cart_rate/1` inverted `compare_at_price` with the caller's (socket) cart struct and took no lock. | Reload with `lock_active_cart!/1` inside the transaction. |
| C8 | NITPICK | `to_base/2` and `base_total/1` rounded to 2 places regardless of the base's `decimal_places`. | `base_decimal_places/0` (cached base read, fallback 2). |
| C9 | NITPICK | `fx_rate_drift_alert_pct` was the only shop setting without the `shop_` prefix. | Reads `shop_fx_rate_drift_alert_pct`, falls back to the old key only while the new one is unset. |
| C10 | NITPICK | `compat/shop.ex` lacked delegates for the week's new public functions. | Added (`currency_for_code/1`, `refresh_cart_rate/1`, `cart_rate_drift/1`, `reprice_for_base_change/3`, `rebase_cart/1`, `present_shipping_method/2`, `fx_rate_drift_alert_pct/0`). |

Verified fine: order freeze (reload + lock + stamp), no client-controlled
currency/rate/price, provenance conversion applied exactly once, the
Shopify currency verdict computed once per run and code-supplied, every
apply event behind `Authz.authorize(:run_imports)`.

### ProductSource / catalogue storefront (#34 #35 #40 #53 #54)

| # | Severity | Finding | Resolution |
|---|---|---|---|
| Q1 | BUG - MEDIUM | `FilterHelpers.parse_filter_params/2` had no clause for a map (`?vendor[x]=y`) and `parse_decimal/1` none for a list (`?price_min[]=1`); called with raw params in every storefront mount, so a linkable URL 500s `/shop`, `/shop/category/*`, `/shop/product/*`. | Catch-all clauses; list branch filtered to binaries. Tests for the three shapes. |
| Q2 | BUG - MEDIUM | Catalogue `filter_by_search/2` matched only the primary `name`/`description` columns; a `/fr/shop?search=` for a translated name returned nothing. | `EXISTS (SELECT 1 FROM jsonb_each(data) …)` over `_name`/`_description`, parameterised. |
| Q3 | BUG - MEDIUM | Admin category search was a silent no-op on the catalogue source (`apply_category_filters/2` ignored `:search`). | `filter_by_category_search/2`. |
| Q4 | IMPROVEMENT - MEDIUM | Query amplification: `catalogue_uuid/0` (config + `list_catalogues`) on every Query function, `AttributeSets.list_sets/0` per filter per call site, `get_enabled_storefront_filters` fetched twice per page. | `catalogue_uuid` and the set list resolved once per facade call and threaded through opts; `aggregate_filter_values/1` accepts `:filters`. `ProductSource.current/0` still does one PK read per call — see *left open*. |
| Q5 | BUG - MEDIUM | Admin `status: "archived"` filter and `View.product_status/2` disagreed on a retired item with a stale `shop_status`. | `CASE WHEN i.status <> 'active' THEN 'archived' ELSE COALESCE(shop_status,'active') END`. |
| Q6 | BUG - MEDIUM | Numeric JSON `price_modifiers` leaves were silently treated as zero by the option layer. | `View` stringifies numbers; `ItemCommerce.changeset/2` now validates every leaf parses as a Decimal. |
| Q7 | BUG - MEDIUM | Legacy raw SQL hardcoded `phoenix_kit_shop_products` without the schema prefix (facets came back `[]` on a prefixed install via the `rescue`). | Built from `Product.__schema__(:prefix)`/`(:source)`. |
| Q8 | NITPICK | `count_items/1` unused; `filter_by_category/2` duplicated; `search_like_pattern/1` duplicated across adapters; a "sitemap" comment for a page that does not exist. | Removed / folded / shared on `ProductSource`. |

Verified fine: every `fragment(` in `query.ex` is parameterised, no user
string reaches SQL or a jsonb path key; ILIKE escaping; #53's retired-item
reachability fix is complete on listing, facets, slug lookup, add-to-cart
and conversion; add-to-cart recomputes price from the reloaded product and
rejects specs outside the product's own selection; no per-card N+1.

### Shopify sync, image importer, Markdown (#36 #42 #47 #48 #49 #50 #55)

| # | Severity | Finding | Resolution |
|---|---|---|---|
| S1 | BUG - MEDIUM (security) | `HtmlToMarkdown` decoded `&lt;`/`&gt;` in text nodes, so an escaped `&lt;script&gt;` example became a raw HTML block; the sanitizer catches it by default, but `shop_allow_raw_html_descriptions=true` executes it, the converter's documented `<script>` stripping was bypassed by the entity form, and idempotence broke. `javascript:` hrefs were copied verbatim. | Markup entities stay encoded in text (CommonMark decodes them at render); unsafe link schemes drop to plain text. |
| S2 | BUG - MEDIUM (security) | DNS rebinding: `private_host?/1` resolved the name, then Req resolved it again. | Resolve once, pin the vouched address in the URL, keep the hostname for SNI/verification and the `host` header, on every hop. |
| S3 | BUG - MEDIUM | The 50 MB limit was checked after the whole body was buffered. | `content-length` pre-check and a streaming `into:` collector that halts at the cap. |
| S4 | BUG - MEDIUM | The media worker isolated products only on `{:error, _}`; any raise (an image with `src: nil` hits a `is_binary` guard) failed the whole run and Oban retried from product 1. | Per-product `rescue`/`catch`, recorded through `product_error/2`; a missing `src` is skipped with a recorded error. |
| S5 | BUG - HIGH | `Writer.sync_variants/2` created attribute sets with no `actor_uuid`; entities' `created_by_uuid` is NOT NULL, so every set creation fails against the current catalogue (8 `:catalogue` tests). | `sync_variants/3` takes opts; the worker threads the job's `actor_uuid` into `create_set/2` and `ValueResolver.resolve_many/3`. |
| S6 | IMPROVEMENT - MEDIUM | `ShopifySync.render/1` re-ran `TextDiff.summary/2` for every loaded row on every render, including the progress messages the worker sends every 20 products. | Summaries cached in a `@diffs` assign keyed `{field, uuid}`, refreshed only when `@changes`/`@page`/expansion change. |
| S7 | BUG - MEDIUM (docs) | README, AGENTS.md and the install task told hosts to configure queues `shop_import`/`shop_images`; every worker uses `shop_imports`, so a host following the docs runs no jobs. | Corrected in all three. |
| S8 | BUG - MEDIUM | Additive per-option modifiers silently under-price a non-additive Shopify matrix (S/L × Red/Blue at 10/12/15/20 sells L-Blue at 17). | `VariantMapper.build/1` reconstructs each variant's price and returns `warnings`; the worker records them per product. |
| S9 | NITPICK | Image reuse path (a) trusted `image_ids` uuids without a liveness check. | Active-uuid set built from the same query as the URL index. |
| S10 | NITPICK | Numeric Shopify ids interpolated into URL paths without a guard. | `numeric_id/2`; `check_one/3` surfaces `:invalid_product_id`. |

Verified fine: token never logged; `Retry-After` clamped; IP-literal
shorthand/decimal/hex/octal forms all blocked; SVG behind
`Policy.allow_svg_uploads?/0`; no path traversal (Storage names files by
hash); Oban uniqueness; override-bucket mirroring; collection ordering.

### Web layer (#37 #41 #44 #46 #48 #51 #52)

| # | Severity | Finding | Resolution |
|---|---|---|---|
| W1 | IMPROVEMENT - MEDIUM | `NamePrefix.strip/1` read the setting through core's cache — a `GenServer.call` — once per product card, category tile and sidebar entry (100+ serialised calls per catalog render). | `strip/2` and `get_display/4` take precomputed prefixes; each page/component reads them once per render. `show_cart_bar?/0` likewise computed once. |
| W2 | BUG - MEDIUM | The category "may still be reachable by direct link" warning in the catalogue shop-status column fired on a leak `View.category_status/2` had already closed. | Warning and its dead `contradiction` plumbing removed; tests inverted. |
| W3 | NITPICK | `save_name_prefixes` had no type guard; `update_category_display`/`update_category_icon` stored the client value without a whitelist. | Guards plus a fallback clause flashing "Invalid value". |

Verified fine: the admin Edit links are gated on `shop.manage_catalog`
server-side from the scope, fail closed on nil, use server-built
`return_to`, no `target=_blank`, no hardcoded URLs; every settings event
re-checks `:manage_settings` and derives toggles from server assigns; no
`raw/1` on user or Shopify text; SEO helpers emit no JSON-LD.

### Infrastructure, dependencies, docs, tests

| # | Severity | Finding | Resolution |
|---|---|---|---|
| I1 | BUG - HIGH | Core floor `~> 2.15` admitted 2.15.x, which tops out at V183; the cart freeze columns are V186, first shipped in 2.16.0. The pin test actively REQUIRED admitting 2.15.0/2.15.1. | `~> 2.16`; 2.15.x moved to `@must_reject`; floor test asserts V186. Lock already carries 2.22.15. |
| I2 | BUG - HIGH (tests) | `test_helper.exs` never applied entities' and catalogue's migration chains, so every `:catalogue` test failed on `undefined_column: slug` in setup (136 tests) whenever the path bridge was on. Billing's chain was applied twice. | Chains applied in the documented order; duplicate removed; landmine recorded in AGENTS.md. |
| I3 | BUG - MEDIUM | `default.pot` stale; two literals unextracted; six status-column strings untranslated in ru/et. | Extracted, merged `--no-fuzzy`, translated (ru/et/de/fr) — zero empty or fuzzy entries. |
| I4 | IMPROVEMENT - MEDIUM | CHANGELOG 0.5.0 omitted the two hard-floor raises (`phoenix_kit` → 2.15, `phoenix_kit_billing` → 0.13) and the new `mdex` dep. | Added under 0.5.0 "Changed". |
| I5 | NITPICK | AGENTS.md: billing pin `~> 0.11` vs `~> 0.13`; "nothing here calls `PhoenixKitCatalogue` directly" vs 46 call sites; tree listing missing `product_source/`, `html_to_markdown.ex`, `name_prefix.ex`, the writer/status-column modules and `ShopifyMediaSyncWorker`; `shop_product_source` undocumented; `shop_inventory_tracking` documented as live; conformance-test path wrong. | Corrected. |
| I6 | NITPICK | Core's local storage provider writes to `priv/media` when a bucket has no endpoint; the `:catalogue` media tests left it in the working tree. | `.gitignore`. |

Verified fine: `mix.lock` consistent; no post-floor core/billing API
adopted without a guard; every `test/support` file in the require list;
`async: false` files all mutate process-global state; migration chain
untouched this week.

## Left open

- **`ProductSource.current/0` is one primary-key read per facade call**
  (~7 per storefront page). The switch lives in `phoenix_kit_shop_config`,
  not `PhoenixKit.Settings`, so there is no cached read and no invalidation
  hook for a per-node cache. Moving the key to Settings is the real fix and
  changes the contract for every writer (tests included).
- **`reprice_for_base_change/3` refuses the catalogue product source.** A
  base-currency change on a catalogue-backed shop is therefore impossible
  until a catalogue reprice pass exists. Documented; not built.
- **Cart and checkout mounts do not rebase a stale cart.** The rebase runs
  on the next add, refresh, merge or conversion, so nothing writes a
  mixed-base line, but a shopper who only looks at their cart between the
  base change and their next action sees pre-rebase figures.
- **`compat/`** — no host app in the workspace and no core release
  references `PhoenixKit.Modules.Shop.*` any more, so the TODO's removal
  condition is met; but the user-order pages are still reached only through
  that namespace, so removal needs those routes registered here first.
- **A "whole set applies" attachment (empty selection) renders no picker**
  and its price modifiers are unreachable. Catalogue documents the empty
  selection as intentional; whether the storefront should surface every
  value is a product decision.
- **Duplicate value labels collapse** in the picker (`Map.new` keyed by
  label). Rare; needs a dedupe strategy.

## How the review was run

Five read-only reviewers in parallel (currency, product source, Shopify,
web, infra), each asked to verify by reading the code path and to drop
anything unconfirmed. Three fix agents with disjoint file ownership; the
call-site edits spanning ownership boundaries and the infra fixes were
applied by hand. Gate: `mix precommit`, the full suite, and the
`:catalogue`-tagged suite against the sibling `phoenix_kit_catalogue` /
`phoenix_kit_entities` checkouts through the `mix.exs` path bridge (with
`MIX_BUILD_PATH` pointed outside the repo so the lockfile stays untouched).
