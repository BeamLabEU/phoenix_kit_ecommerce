# PR draft — Render the storefront in the host layout, add price units, split shop permissions

**Base:** `BeamLabEU/phoenix_kit_ecommerce` `main` ← **Head:** `mdon:main`
**Commits:** 13 (`55e2c62..HEAD`) · 53 files, +7509/−4005 · **321 tests, 0 failures**

> Paste the body below into `gh pr create`. Nothing here bumps `@version`
> or touches `CHANGELOG.md`.

---

## Summary

A host app (revalfilm.info) reported that catalog, category and product
pages ignore the host's layout: the storefront looked like a separate
application. Fixing it turned into a full pass over the storefront, and
two adversarial review rounds against my own fixes found more — including
money defects in the fixes themselves.

Also here: the price-unit feature the same host asked for ("€40 **per
hour**"), and the module's first use of core's sub-permission,
notification and money-path audit systems.

## The reported bug

`ShopLayouts.shop_layout/1` dispatched three ways: a self-contained
`shop_public_layout` for guest catalog pages (bypassing the host's
`layouts_module` entirely — the reported bug), the **admin dashboard**
layout for any authenticated visitor (so a logged-in shopper got admin
chrome on cart and checkout too), and the host layout only for guest
cart/checkout.

Every storefront page now renders through core's
`LayoutWrapper.app_layout`. The catalog templates had guest-only
sidebar/grid branches — authenticated users got the sidebar injected into
the dashboard layout via `sidebar_after_shop` — so those branches are
unified rather than deleted; without that, the fix would have silently
removed filters and category navigation for every logged-in shopper.

Because the module no longer ships storefront chrome, a compact in-content
Shop/Cart bar with a live item count renders on catalog pages, behind
`shop_show_cart_bar` (default on, admin toggle) for hosts whose own header
already links to the cart.

## Defects fixed alongside it

**Money**
- tax/total shown at review could differ from what was charged: two paths
  reached `:review` without pricing the cart, and a cart change broadcast
  from another tab was assigned into an open review, dropping the country
  and its tax
- conversion judged the shipping method on TOTAL weight while listing and
  pricing used shippable weight, so a mixed cart was quoted a method and
  then refused at checkout
- `find_cheapest_shipping_method/2` used `Enum.min_by` on `%Decimal{}` —
  term order, not value, so `9.99` sorted above `10` and cart mount could
  auto-select the dearer method
- the advertised price range skipped map-shaped override modifiers that
  the charged path parses: "From $20" for an item that charges $30
- an offered option value with no modifier entry was skipped instead of
  contributing a zero delta, so a product whose cheapest option is free
  advertised its most expensive combination
- cart/checkout/order pages rendered today's default currency instead of
  the amount's own
- `requires_shipping` was decorative: digital-only carts were forced
  through shipping selection and charged for it
- the selected payment option was discarded at conversion
- order pages preferred the LIVE billing profile over the order's
  snapshot, so editing a profile rewrote history

**Correctness / security**
- a disabled shop stayed fully browsable and purchasable
- `body_html` was never rendered on the public product page (imports put
  the full supplier description there)
- a product could be added to a cart, and a cart converted, while the
  product was no longer active — the conversion check now runs on locked
  rows inside the transaction
- blank-address orders: completeness is validated in the CONTEXT for both
  billing paths (billing never required a profile to carry an address)
- the product page's PubSub handlers trusted the broadcast payload (an
  unpreloaded association crashed the view) and kept a selected option
  value whose key survived but whose value the product no longer offers

## Price units

`PhoenixKitEcommerce.PriceDisplay` renders `From €40.00 per hour`. Storage
is one reserved metadata namespace (`_price_display`), free text per
language — no migration, and no unit vocabulary to maintain. `render/4`
takes an explicit **context**: catalog may show "From"; `:selected`,
`:cart` and `:order` are exact and render the SNAPSHOTTED unit, so an edit
or deletion cannot relabel a line a customer already agreed to. The unit
rides into the order's line items, so it reaches billing's invoices with
no billing-side change.

## Permissions, notifications, audit

Four sub-permissions (`manage_catalog`, `manage_carts`, `manage_settings`,
`run_imports`) with tabs carrying their key and 48 mutating handlers
re-checking through the new `Web.Authz`. Notifications for order placement
(admins) and order confirmation (the customer, muteable) plus import
completion. The money path is audited on success AND failure.

⚠️ **Breaking on upgrade:** core auto-grants new sub-permissions to the
Admin system role only, so a CUSTOM role holding base `"shop"` keeps its
reads but loses mutations until an operator re-grants. Secure by default
and deliberate — but it needs saying in the release notes.

⚠️ **Audit action strings are deliberately NOT the notify action strings.**
`Activity.log/1` auto-derives notifications from registered actions; a
shared string delivers a duplicate. A test pins the contract.

## Verification

- `mix precommit` exit 0 (compile --warnings-as-errors, format, credo
  --strict, dialyzer)
- 321 tests, 0 failures — **both** against the Hex pin and
  `PHOENIX_KIT_PATH=../phoenix_kit`; 5 consecutive runs stable
- browser-verified through `phoenix_kit_parent`: storefront as guest AND
  logged-in against pre-change screenshots, admin pages structurally
  unchanged, the price unit rendering live, and a host-built storefront at
  the parent's own `/colors` URL proving the context API supports a host
  writing its own catalogue UI while sharing the module's cart

## Test plan

- [x] 321 tests, 0 failures (Hex pin)
- [x] 321 tests, 0 failures (local core)
- [x] 5/5 consecutive stable runs
- [x] `mix format --check-formatted`, `credo --strict`, `dialyzer`
- [x] Browser tour: guest + authenticated storefront, admin surface, price
      units, host-built shop
- [x] Denied-scope tests that fail if an authorization gate is removed
