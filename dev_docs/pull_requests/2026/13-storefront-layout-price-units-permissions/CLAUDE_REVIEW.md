# Code Review: PR #13 — Render the storefront in the host layout, add price units, split shop permissions

**Reviewed:** 2026-08-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/13
**Author:** Max Don (mdon)
**Head SHA:** `9032ec969b117dcc97ad3efae8374118aa85b61e`
**Merge commit:** `debacc8`
**Status:** Merged

## Summary

65 files, +8642/−4167 across three themes: every storefront page now renders
through the host's `LayoutWrapper.app_layout`; `PriceDisplay` adds an optional
per-language price unit and "From" prefix; and the module gains four
sub-permissions, notifications and money-path audit rows.

This is a post-merge review of a PR that already carried three adversarial
review rounds and shipped its own `FOLLOW_UP.md` with eleven recorded open
items. This review therefore does **not** re-derive what that document already
records — items 1–11 there stand as written and are not repeated here. What
follows is what survived that process.

## Issues Found

### 1. [BUG - MEDIUM] The price unit is rendered against the line TOTAL on both order pages — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/checkout_complete.ex` lines 276-280;
`lib/phoenix_kit_ecommerce/web/user_order_details.html.heex` lines 52-57
**Confidence:** 92/100

Both order pages rendered:

```elixir
PriceDisplay.render(nil, @currency, :order, amount: item["total"], unit: item["price_unit"])
```

`item["total"]` is the **line total** — `convert_cart_to_order/2` writes
`"unit_price" => item.unit_price` and `"total" => item.line_total` as separate
keys (`phoenix_kit_ecommerce.ex:3011-3019`), and the markup immediately to the
left prints `× {item["quantity"]}`. So a line of 2 hours at €40.00 per hour
rendered as **"€80.00 per hour"**: a receipt stating a rate the customer never
agreed to, on the two pages whose entire job is to be an accurate record of
what was charged.

The cart page had it right — `cart_page.ex:404` renders `item.unit_price` with
the unit and appends "each", leaving the line total plain above it. The two
order pages are the same feature written the other way round.

This is precisely the case the module's own design guards against: the
`:cart`/`:order` contexts exist so a snapshot renders "the price for one of
these, as the customer saw it". Attaching that unit to an extended total
defeats it for every quantity > 1. Quantity 1 renders correctly, which is
presumably why it survived the browser tour.

**Fix applied:** both pages now render the line total plain and, when the line
stored a unit, add the cart page's subline — `unit_price` + unit + "each".
Shipping lines carry no `price_unit` and are unaffected.

### 2. [BUG - MEDIUM] `Notifications.truncate/2` splits UTF-8 mid-character, silently losing the import-failure notification — FIXED

**File:** `lib/phoenix_kit_ecommerce/notifications.ex` line 181
**Confidence:** 88/100

```elixir
defp truncate(text, max) when byte_size(text) > max, do: binary_part(text, 0, max) <> "…"
```

`binary_part/3` cuts on **bytes**. `import_failed/2` is its only caller and
feeds it `to_string(reason)` — an import failure reason, which routinely
carries the row or product title that caused it. On this module's own stated
use case (a Ukrainian catalogue, Cyrillic titles) a cut at byte 120 lands
mid-character with high probability, producing an invalid UTF-8 binary.

Postgres rejects invalid byte sequences for a UTF8 database, so the
notification insert raises — and `safely/1`, which exists so a notification
can never take down the thing it reports on, swallows it and logs a warning.
The net effect is that the *failure* notification goes missing exactly for the
non-ASCII catalogues where imports are most likely to fail: silence when the
operator most needs to hear.

The wrapper is right; what is wrong is producing a value that cannot be
stored. **Fix applied:** `String.slice/3`, which cuts on graphemes.

No test: the helper is private and every public entry point into it requires a
database (unavailable here — see Verification).

### 3. [OBSERVATION] `put_shop_session/3`'s `trusted?` argument is now always `true`, and its comment describes a design that was replaced

**File:** `lib/phoenix_kit_ecommerce/web/plugs/shop_session.ex` lines 73-91

The 14-line comment above `put_shop_session/3` explains that an adopted
legacy cookie is marked **untrusted** and that "the cost is one request:
adoption re-issues the cookie signed, so the visitor's NEXT request is
trusted". That was true of the first design. The current one is better — the
`{:legacy, _}` branch mints a *fresh* id and re-keys the cart onto it, so a
replayed value can never become a trusted session at all — but it means all
three call sites now pass `trusted?: true`, the untrusted state is
unreachable, and `CheckoutComplete`'s `session["shop_session_trusted"] == true`
check can no longer fail.

Not a defect: the dead argument is harmless and the check is correct
defence-in-depth if an untrusted path is ever reintroduced. It is recorded
because the comment currently teaches the reader a rule the code no longer
follows, and that is how a future change re-adds `trusted?: false` at a call
site that nothing tests.

One related nuance the comment overstates: it claims "the legitimate visitor
keeps their cart". In the replay case they do not — `rekey_cart_session/2`
moves the cart onto the *replayer's* new id, and the legitimate visitor's next
request finds no cart for their own legacy value and starts a fresh one. That
requires an attacker to obtain a real 32-byte session id out of band, inside
the legacy window, before the victim's own next visit, and it costs a cart
rather than an order — narrow enough to accept, but it is a trade, not an
absence of one.

### 4. [OBSERVATION] `format_product_price/3` is now a second, diverged price renderer on the public API

**File:** `lib/phoenix_kit_ecommerce.ex` lines 1019-1037

`PriceDisplay.render/4` replaced it everywhere inside the module — no
storefront template calls it any more — but it is still exported and still
re-exported by `compat/shop.ex:65`, so hosts that build their own catalogue UI
(a use case this PR explicitly verified in the browser) are calling it. It
hardcodes an untranslated `"From"`, hardcodes the `$` fallback, and knows
nothing about units, so a host using the documented API now renders prices
differently from the module's own pages.

Not fixed: changing a public function's output is a breaking change for hosts
relying on it, and the right move is a deprecation pointing at
`PriceDisplay.render/4`, which is a decision rather than a review fix.

## What Was Done Well

- **The permission split is complete, not decorative.** Every mutating
  `handle_event/3` across the twelve admin LiveViews is gated: settings 16/16,
  imports 8 of 21 (the other 13 are form/modal state), import configs 4,
  options 4, catalog 4+4+1+1, shipping 2+1, carts guarded at mount because the
  rows carry customer contact details. `test_shop.ex`'s three ungated handlers
  are genuinely read-only (`test_cart_with_specs/0` inspects
  `CartItem.__schema__(:fields)`; nothing writes). The `Authz.authorize/3` →
  private `gated_event/3` pattern keeps 48 handler bodies at their original
  nesting level.
- **The audit/notify action-string separation holds.** Cross-checking all 22
  `Activity.log*` action strings against the four registered notify actions
  finds no overlap, so no audit row can deliver a duplicate notification. The
  contract is pinned by a test, which is what will keep it true.
- **The `@payment_option_version` guard is correct and was re-verified.**
  `deps/phoenix_kit/.../v162.ex` is indeed the migration adding
  `payment_option_uuid`, and V161 is the unrelated citext change — the
  correction in `9032ec9` was necessary and lands on the right number. Caching
  a `false` in `:persistent_term` until restart is documented at the call site.
- **The `Decimal` term-order class of bug was fixed everywhere, not just where
  it was found.** A sweep of every `min_by`/`max_by`/`sort_by` in `lib/` finds
  the shipping selector carrying an explicit `Decimal.compare/2` comparator and
  every remaining sort keyed on integers or strings.
- **The raw-HTML policy is applied at both ends.** Admin preview
  (`product_detail.ex:874`) and the public product page
  (`catalog_product.ex:775,787`) both consult
  `Policy.allow_raw_html_descriptions?/0`, and the two `String.to_atom/1` calls
  in `option_builder.ex` are over a bounded `1..10` range, not user input.

## Verdict

**Approved with fixes.** Two real defects — one of them on a receipt, which is
the least forgiving surface in the module — plus two recorded observations.
Given the size (8.6k lines added) and that both defects are single-expression
mistakes in otherwise correct new subsystems, the review rounds this PR
already went through clearly did most of the work.

## Verification

- `mix precommit` — see the release commit; run after the fixes.
- ⚠️ **No PostgreSQL in this environment.** `mix test` ran **111 tests, 0
  failures, 238 excluded** — every `:integration`-tagged test was auto-excluded
  per the harness described in AGENTS.md. The two fixes above are therefore
  verified by reading the code paths and by the gate, not by execution: fix 1
  is a template change on a page whose test requires a seeded order, and fix 2
  is in a private helper reachable only through a database write.
- One gate blocker was pre-existing and unrelated to either PR: `mix precommit`
  failed at `deps.unlock --check-unused` on eight stale `mix.lock` entries
  (igniter, sourceror, spitfire, rewrite, owl, ex_ast, glob_ex, text_diff) left
  behind by `3b5d85c "lib upgrades"`. Pruned with `mix deps.unlock --unused`.
