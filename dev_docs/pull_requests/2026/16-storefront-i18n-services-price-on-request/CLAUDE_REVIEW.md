# Code Review: PR #16 — Translate the storefront, add services/price-on-request, and fix ten reported defects

**Reviewed:** 2026-08-08
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/16
**Author:** Max Don (mdon)
**Head SHA:** `ccf920124091be39934f48e13e1768321a6e21b9`
**Merge commit:** `77ec7b9`
**Status:** Merged

## Summary

Nine commits across three themes:

1. **i18n** — wraps storefront strings, and fixes the reason a wrapped string
   still rendered English: the content language is a dialect (`ru-RU`) and the
   catalogues are plain codes (`ru`), between which Gettext does not fall back.
   `Helpers.put_content_locale/1` resolves one against the other and is called
   from every public `mount/3`.
2. **Two new presentation axes** — `PhoenixKitEcommerce.Vocabulary`
   (products / services / mixed, one complete `gettext` literal per variant) and
   "price on request", snapshotted onto the cart line and forwarded into the
   order line so a deleted product cannot turn an agreed non-price into `0.00`.
   Plus `shop_hide_zero_decimals` for storefront-only decimal trimming.
3. **Ten reported defects** — Cyrillic category slugs, the double cart link, the
   duplicated mobile category list, the empty filter drawer, the false
   confirmation-email promise, a one-click status toggle, and others.

The architecture is right, and the reasoning recorded in the module docs is
unusually good. What it got wrong is *reach*: three of its own contracts are
applied at some call sites and not others, and in each case the sites it missed
are the ones closest to the money.

## Verification

**The dialect→base locale fix is real and correctly placed.** `mount/3` runs
once per process for both the dead render and the connected mount, so setting
the process locale there covers the LiveView's whole lifecycle, and the
unknown-locale branch *resets* rather than no-ops — correct, because the dead
render runs in a connection process reused across keep-alive requests. All eight
public LiveViews now call it.

**The Cyrillic slug fix is correct and now matches Product.** Core's
`Slug.slugify/2` with `transliterate: true` maps Cyrillic before the ASCII pass
(`[^a-z0-9]+/u`), and Estonian diacritics survive via the NFD strip. The old
local version used `\w` without `/u`, which matches no Cyrillic, so a Russian-only
category name was stripped to `""`. Category and Product now share one
implementation. Note existing rows are *not* migrated — a category stored with
an empty slug regenerates on its next save (`maybe_generate_slug/1` treats `""`
as absent), so the fix is retroactive only on re-save.

**The price-on-request snapshot chain holds** — `CartItem.from_product/3` writes
the flag, `build_order_line_items/1` forwards it, and both are pinned by tests.

**The catalogues are complete.** 692 msgids × 3 locales, zero untranslated,
zero fuzzy, Russian plural header carrying three forms. `mix gettext.extract
--check-up-to-date` is clean.

## Issues Found

### 1. [BUG - HIGH] `shop_hide_zero_decimals` does not hide decimals — it rounds the price — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/helpers.ex` lines 60-75 (pre-fix)
**Confidence:** 99/100

Trimming is implemented by handing billing a copy of the currency with
`decimal_places: 0`. But `Currency.format_amount/2` *rounds* to
`decimal_places`:

```elixir
amount |> to_decimal() |> Decimal.round(places) |> format_with_thousands()
```

and the copy was made whenever the setting was on, with no regard for the
amount. Verified against the resolved billing dependency:

| Amount | `decimal_places: 2` | `decimal_places: 0` |
|---|---|---|
| `40.00` | €40.00 | €40 ✅ |
| `40.50` | €40.50 | **€41** ❌ |
| `40.49` | €40.49 | **€40** ❌ |
| `1234.99` | €1,234.99 | **€1,235** ❌ |

Every storefront figure goes through `format_price/2` — the catalog price, the
cart line, the per-unit line, shipping, tax, the subtotal and the total — so a
shop that turns this on advertises and totals prices it will not charge. It is
also the opposite of the documented contract, in AGENTS.md ("when the fractional
part is entirely zero"), in the function's own `@doc`, and in the sibling
branches: `format_price(price, code)` routes through `trim_decimals/2`, which
correctly trims only when nothing is lost. The currency branch — the only branch
a shop with a configured currency ever reaches — disagreed with the other two.

`helpers_locale_test.exs` states this exact contract in a comment ("the
plain-code and nil branches must agree with the currency branch about WHEN to
trim") and then only exercises the plain-code branch, which is why it shipped.

**Fix applied:** the amount is now passed to `display_currency/2`, which zeroes
the places only when `Decimal.round(amount, places)` is unchanged by rounding to
zero. Non-Decimal amounts answer "not whole" and keep the currency's own
precision — billing accepts shapes `Decimal.round/2` raises on. The test was
extended to cover the currency branch, including a zero-decimal (JPY-style)
currency.

### 2. [BUG - MEDIUM] The checkout review step renders an on-request line as `0.00` — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` lines 1377-1383 (pre-fix)
**Confidence:** 97/100

The whole point of snapshotting `price_on_request` is that a line with no price
must never be formatted, because its stored `unit_price` is `0`. The cart page,
the confirmation page and the order-details page were all converted to route
through `PriceDisplay.render/4`. The **checkout review step was not**:

```heex
Qty: {item.quantity} × {format_price(item.unit_price, @currency)}
...
{format_price(item.line_total, @currency)}
```

So an on-request service reads "Qty: 1 × 0.00" and "0.00" on the last page
before the customer presses Confirm Order — the page the PR's own comment
describes as the reason the forwarding matters. `AGENTS.md` calls this out for
the order line and the cart line; the page between them was missed.

`Qty:` was also a bare literal on an otherwise-translated page.

**Fix applied:** routed through `PriceDisplay.render/4` with the line's own flag,
and the qty line became two whole `gettext` literals
(`"Qty: %{count}"` / `"Qty: %{count} × %{price}"`) rather than a fragment plus
punctuation.

### 3. [BUG - MEDIUM] The product page's "Already in cart" notice has the same defect — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/catalog_product.ex` line 971 (pre-fix)
**Confidence:** 96/100

`{@cart_item.quantity} × {format_price(@cart_item.unit_price, …)} = {format_price(@cart_item.line_total, …)}`
renders "1 × 0.00 = 0.00" in an info alert sitting a few hundred pixels below the
headline price the same PR taught to say "Price on request". The PR wrapped the
`"Already in cart:"` label in this very block and left the numbers.

**Fix applied:** the amounts are suppressed for an on-request line, matching the
cart page's treatment.

The root cause of #2 and #3 is that the question "is this line on request?" was
expressed inline in each template, and the two templates that expressed it were
the two that got it right. Added `PriceDisplay.line_on_request?/1` — accepting
both line shapes, a `CartItem` (flag under `metadata`) and an order line item
(plain map) — and routed all five sites through it, with DB-free tests.

### 4. [BUG - MEDIUM] The checkout page is the least translated page in the module — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` (throughout `render/1` and its components)
**Confidence:** 98/100

`AGENTS.md` singles this page out — "a page can be fully translated and
completely inert at the same time — `checkout_page.ex` was exactly that" — and
the PR fixed the inertness while translating only the flashes and a handful of
headings. Thirty-plus customer-facing strings were left raw English, including
the entire billing form:

`Checkout` · `Billing` · `Review & Confirm` · `Select Payment Method` ·
`Continue to Billing` · `Continue to Review` · `First Name *` · `Last Name *` ·
`Email *` · `Phone` · `Address *` · `Street address` · `City *` ·
`Postal Code` · `Country *` · `Select country...` · `Default` ·
`You have multiple billing profiles…` · `Payment Method` · `Change` (×3) ·
`Billing Information` · `Shipping Method` · `Order Items` · `Edit Cart` ·
`FREE` (×2) · `Processing...` · `Confirm Order` · `Order Summary` ·
`Subtotal (N items)` · `Shipping` · `Tax` · `Discount` · `Total`

A Russian shop's shopper therefore reaches the payment step and is asked for
"First Name *" and "Country *" in English. This is the highest-value page in the
storefront and the one where an untranslated form costs conversions.

Two more in the same class:

- `checkout_page.ex:701` — `assign(:error_message, "Failed to create order.
  Please try again.")`, rendered in an alert on the page, while the `put_flash`
  on the line below it *was* wrapped in the same commit.
- `catalog_category.ex` — `{@total_products} product(s) found`, untranslated and
  hardcoding "product" for a services shop.

**Fix applied:** all of the above wrapped; `Subtotal (N items)` became an
`ngettext/4` (the count is inside the label, and Russian needs three forms for
it); the count line routes through `Vocabulary` (see #6).

### 5. [BUG - MEDIUM] Every add-to-cart failure message is untranslated, in the function the PR edited — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/catalog_product.ex` lines 519-558 (pre-fix)
**Confidence:** 95/100

`get_user_friendly_error_message/2` produces the toast a shopper sees when
add-to-cart fails — out of stock, a stale option, a changed price. All eight
messages were raw English. The PR touched this function: it wrapped
`detail[:key] || gettext("option")` in the first clause and left the sibling
clause's `|| "option"` bare and every returned message untranslated. AGENTS.md's
i18n contract is explicit that "flash messages and `page_title` count — they are
as visible to a customer as anything in the markup".

**Fix applied:** all eight wrapped, with interpolated values as `gettext`
bindings rather than built into the msgid (`%{option}`, `%{value}`, `%{count}`),
so one msgid covers every product. Two of them said "Product"; they now read
neutrally ("This item is out of stock", "The price has changed") so a services
shop is not told about a product — cheaper than a `Vocabulary` clause for a
toast, and stated here so the choice is on record.

### 6. [BUG - MEDIUM] Two vocabulary-dependent strings bypass `Vocabulary` — one of them regressed the default shop — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/components/shop_cards.ex` line 139, `lib/phoenix_kit_ecommerce/web/catalog_category.ex` line 374
**Confidence:** 90/100

`Vocabulary` exists so that no storefront string names what the shop sells
without going through it, and AGENTS.md states the rule: "adding a vocabulary
means adding a clause and a literal to every function in that module". Two
strings that name it live outside the module:

- `shop_cards.ex` replaced `"Showing X of Y products"` with a neutral
  `ngettext("… item"/"… items")`. That is a **regression for the default
  configuration**: a products shop now reads "Showing 12 of 40 items" directly
  under a heading that says "Products".
- `catalog_category.ex` hardcoded `product(s) found` — untranslated *and*
  unconditionally "product".

**Fix applied:** added `Vocabulary.count_found/1` and `Vocabulary.showing_of/2`,
each a complete `ngettext/4` per variant for the reason the module documents (the
count selects the case the noun inflects for; `1 товар` / `2 товара` /
`5 товаров` share no ending). Both call sites now route through them, and
`vocabulary_test.exs` covers the two arity>0 functions the existing
"every variant differs" test could not reach.

### 7. [BUG - MEDIUM] The totals say `0.00`, which is the defect the PR fixed, moved up one level — FIXED

**File:** `cart_page.ex`, `checkout_page.ex`, `checkout_complete.ex`, `user_order_details.html.heex`
**Confidence:** 85/100

`CartItem.from_product/3` deliberately snapshots `unit_price: 0` for an
on-request line, with a sound rationale: the customer never saw the product's
price, so it must not enter a total. The consequence was not followed through.
An on-request line contributes `0` to the subtotal and the total, and the totals
are formatted unconditionally — so:

- a cart holding only on-request services shows **"Total 0.00"** beside an
  enabled "Proceed to Checkout" button;
- a mixed cart shows a total that silently omits the on-request item, which the
  shopper reads as the whole bill;
- the confirmation page and order-details page show the same figure on a
  **committed** order.

This is the same harm the PR's own comment describes ("renders 0.00 where the
customer agreed to price on request"), suppressed per line and left standing on
the sum of those lines.

**Fix applied:** the amounts are left alone — they are what billing computed and
will charge — and the four pages that show a total now disclose what it leaves
out ("Items priced on request are not included in this total.") when any line is
on request, via `PriceDisplay.any_line_on_request?/1`. Deliberately *not* fixed:
whether an on-request line should be checkout-able at all, or whether a quote
workflow belongs here. That is a product decision, not a defect, and inventing
one during a review would be worse than stating the limitation.

### 8. [BUG - MEDIUM] The two public order pages translate against core's catalogue, so `put_content_locale/1` does not reach them — FIXED

**File:** `user_orders.html.heex`, `user_order_details.html.heex`, `user_order_details.ex:55`
**Confidence:** 88/100

Both pages gained `put_content_locale_from/1` in this PR — which sets the locale
on **`PhoenixKitEcommerce.Gettext`**. Eight strings on those pages are
`Gettext.gettext(PhoenixKitWeb.Gettext, …)` — core's backend, whose process
locale is still the dialect core wrote, and whose catalogue has the same
plain-code shape. So `Total`, `Status`, `Pending`, `Completed`, `Clear`, `Next`
and the `Access denied` flash miss their lookup and render the English msgid, on
pages the PR had just pointed at the right locale. Pre-existing calls, but
squarely inside this PR's contract and invisible precisely because the PR's own
fix does not apply to them.

**Fix applied:** the eight public-page calls now use the module's own backend
(and are in its catalogue, translated). **Not** changed: the same construct in
the admin pages (`products.ex`, `categories.ex`, `import_show.ex`) — those are
core's shared UI vocabulary (`Edit`/`Delete`/`View`) on admin surfaces, which the
admin i18n wave owns; converting them is a separate change with its own
extraction cost.

### 9. [NITPICK] An identity `case` in the new status toggle — FIXED

**File:** `lib/phoenix_kit_ecommerce/web/products.ex` lines 921-926 (pre-fix)

```elixir
product =
  case Shop.get_product(uuid) do
    nil -> nil
    fresh -> fresh
  end

case product do
```

Two `case` expressions where one does, the first of them a no-op. Collapsed into
a single `case Shop.get_product(uuid) do %{status: old} = product when …`, which
also binds the struct the update needs instead of relying on the outer variable.

### 10. [NITPICK] `admin_edit_label` is untranslated on three storefront pages — FIXED

**File:** `catalog_category.ex:128`, `catalog_product.ex:147,306`

`assign(:admin_edit_label, "Edit Category")` / `"Edit Product"` — rendered on the
public page for a signed-in admin, so it is storefront markup by any reasonable
reading, and it was the only unwrapped `assign` left on those pages. Wrapped.

### 11. [OBSERVATION] The confirmation page tells the customer to look for an email subject this module does not own

**File:** `lib/phoenix_kit_ecommerce/web/checkout_complete.ex` lines 344-347
**Not fixed.**

The guest block now reads `{gettext("Open the email titled")}
<strong>{gettext("Confirm your account")}</strong>`. The subject line is
rendered from **this** module's catalogue, but the email is sent by core with
core's own subject and core's own translation of it. In any locale where the two
catalogues disagree — or where core's dialect-locale lookup misses, which is the
bug this PR documents — the page instructs the customer to look for a subject
that does not exist in their inbox.

Left alone deliberately: the honest fixes are either to read the subject from
core (which means a core API this module cannot add) or to stop quoting the
subject at all (a copy decision). Guessing at either during a review is how the
false email promise this PR just removed got there in the first place. Recorded
so the next person does not have to rediscover it.

### 12. [OBSERVATION] `Vocabulary.current/0` and `hide_zero_decimals?/0` do not fail closed on a settings error

**File:** `vocabulary.ex:46`, `helpers.ex:89`
**Not fixed.**

Both read settings without a rescue, while `Policy` readers deliberately "fail
*closed* on a settings-layer error". The exposure is small — a storefront page
without a database is not rendering anyway, and the values are cosmetic rather
than a security boundary — and it matches how the surrounding storefront code
already reads `shop_category_icon_mode` and friends. Flagged for consistency,
not fixed: adding a rescue to two of a dozen equivalent readers makes the
inconsistency harder to see, not easier.

## What Was Done Well

- **The dialect/plain-code diagnosis is the good kind of bug report.** Two
  independent failures ("the string is wrapped" and "the backend points at a
  locale the catalogue has") are separated, both are explained with the
  mechanism, and the fix is placed where the lifecycle actually needs it.
  The unknown-locale branch resetting rather than no-opping — because the dead
  render reuses a connection process — is a subtle correctness point that most
  implementations of this get wrong.
- **`Vocabulary` refuses the obvious wrong design and says why.** One noun
  interpolated into `"No %{noun} available"` cannot be translated into Russian or
  Estonian, and the moduledoc explains the case-inflection reason rather than
  asserting a style rule. The cost (more msgids) is stated.
- **"Price on request" is snapshotted, not read live**, with the reasoning tied
  to a concrete mechanism (`product_uuid` is `ON DELETE SET NULL`), and the
  forwarding step that was missed once now has a regression test on both the
  cart line and the order line.
- **`on_request` is written only when true**, so `build/2` produces exactly the
  map it always did and no existing product gains a key on save. That is the
  detail that makes the migration a non-event.
- **The dead `function_exported?/3` shim was removed rather than kept**, with an
  honest note that it only ever appeared to work on a dev box resolving billing
  through a path dep. Deleting your own clever workaround and documenting why is
  rare.
- **The category slug fix converges on Product's implementation** instead of
  patching the regex locally — one slugifier, and the comment names why the old
  one failed (`\w` without `/u`).
- **The status toggle re-reads the row rather than trusting `socket.assigns`**,
  refuses to guess at the archived transition, and logs the failure branch as
  well as the success branch.
- **The settings radio group is driven by `Vocabulary.options/0`**, the same list
  the handler validates against, so the UI and the validator cannot drift.
- **Translations are complete and plural-correct** in all three catalogues,
  with Russian's three forms actually filled in.

## Verdict

**Approved with fixes.** Every claim in the PR checks out, the two new features
are designed the right way round, and the module documentation it leaves behind
is better than the code it describes. The failures are all failures of reach
rather than of judgement — three contracts the PR itself introduced or restated
(route snapshot lines through `PriceDisplay`, name what you sell through
`Vocabulary`, wrap what a customer reads) were applied at most call sites and
missed at the ones on the checkout path, and the one outright logic bug turns a
cosmetic setting into misstated prices. Twelve findings: ten fixed, two recorded
as limitations with reasons.

## Post-review state

- **Gate:** `mix format`, `mix compile --warnings-as-errors`,
  `mix credo --strict` (no issues), `mix dialyzer` (2 errors, 2 skipped — the
  pre-existing `.dialyzer_ignore.exs` entries) all clean.
- **Tests:** 115 pass, 0 failures. The 265 excluded are `:integration` — this
  environment has no PostgreSQL, so the new `format_price` currency-branch,
  `Vocabulary` count, and cart-snapshot assertions are DB-gated and did not run
  here. The five new `PriceDisplayLinesTest` cases are DB-free and pass.
- **Catalogues:** 48 new msgids, extracted and merged with `--no-fuzzy`;
  en/ru/et complete with zero untranslated and zero fuzzy entries;
  `mix gettext.extract --check-up-to-date` clean. The ru/et copy for the newly
  wrapped checkout markup is agent-authored to the same standard as the rest of
  the catalogue and is worth a native-speaker pass.
