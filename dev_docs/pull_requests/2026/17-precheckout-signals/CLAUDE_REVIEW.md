# Code Review: PR #17 — Pre-checkout signals and shipping-skip modes

**Reviewed:** 2026-08-09
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/17
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** `5cb26172e2ec66dd1ac764aa7386e673e7a60358`
**Merge commit:** `80f7537`
**Status:** Merged

## Summary

The PR describes two features. It **merged four**.

Described:

1. **Cart-activity notifications** — three individually-toggleable storefront
   signals (first item in a cart, every item, checkout started) fanned out
   through core's notification layer, deduplicated per cart by an atomic
   `UPDATE … WHERE NOT (metadata ? flag)` jsonb claim, and best-effort by
   construction. Plus a settings card of toggles and a recipient picker.
2. **Shipping-skip modes and selection position** — `shop_shipping_skip_mode`
   (`off`/`fallback`/`always`) and `shop_shipping_selection_position`
   (`cart`/`checkout`), with a new post-billing `:shipping` step, a localized
   "we will contact you" fallback, `shipping_skipped`/`shipping_skip_reason`
   stamped onto order metadata, and server-side re-validation in
   `convert_cart_to_order/2` independent of the LiveView.

Also merged, mentioned nowhere in the PR body or the CHANGELOG entry the PR
itself wrote — the branch had earlier merged `phase4-catalog-ai`:

3. **AI product translation** — `PhoenixKitEcommerce.AITranslatable` (303 lines),
   the product form's translate button/modal, and a **new optional dependency**
   `phoenix_kit_ai ~> 0.17` in `mix.exs`. The PR body states "no dependency or
   version changes."
4. **Multi-domain catalog SEO** — `Web.SEOHelpers` (171 lines) wired into the
   catalog, category and product LiveViews, plus a product-URL language-choice
   fix in `catalog_product.ex`.

The two described features are well built. The reasoning recorded in the module
comments is, as in PR #16, unusually good — `validate_shipping_method_available/1`
explains exactly why the skip decision must run after
`apply_checkout_shipping_country/2`, and the `claim_cart_flag/2` docstring is
precise about what "exactly once" means. The concurrency test that races eight
processes at the same cart/flag is the right test to have written.

What went wrong is concentrated in the **new checkout position**: it is the one
path where the cart page and the checkout page must agree about who owns the
shipping choice, and they did not. And the gate the PR claims to have run was
not green.

## Verification

**The atomic claim is genuinely atomic.** `UPDATE … WHERE NOT (COALESCE(metadata,
'{}') ? flag)` with `count == 1` is the right shape, the `\\?` escape for the
jsonb operator is correct, and `notifications_test.exs` contends it with eight
concurrent tasks rather than inferring atomicity from the SQL.

**The skip decision is correctly ordered.** `validate_cart_contents/1` defers to
`validate_shipping_method_available/1` for anything but `:off`, and that runs
after `apply_checkout_shipping_country/2` — the country the decision is about
does not exist on the cart before then. `build_order_attrs/4` reads the reason
off the in-memory stamp; the durable record is the order's metadata, as the
comment says.

**`calculate_shipping/3` returning 0 is a real fix**, not a cosmetic one: the
caller writes the result straight back onto `cart.shipping_amount`, so echoing
the old value persisted a charge for a method that was no longer selected.

**`shipping_selection_still_valid?/1` calls the same `shipping_skippable?/1` the
conversion calls** — review cannot approve a total the conversion then refuses.
Correct, and the reason it is correct is written down.

## Issues Found

### 1. [BUG - HIGH] Checkout dead-ends under `position: "checkout"` — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` (`enter_review/1`)
**Confidence:** 95/100

`enter_review/1` responds to a no-longer-eligible shipping method by flashing
"please pick another" and `push_navigate`-ing to `/cart`.

Under `shipping_selection_position: "checkout"` the cart page renders **no
shipping section at all** — that is precisely what the setting does
(`CartPage.shipping_required_here?/0`, and the template gate on
`@shipping_required_here`). So the shopper lands on a page with nothing to
change. "Proceed to Checkout" is enabled (the disable condition requires
`@shipping_required_here`), and checkout's own `mount/3` then rejects the same
stale method through `selected_shipping_method_outgrown?/2` and redirects back
to `/cart`. A closed loop, with the ineligible selection never cleared by either
side — `reconcile_shipping_selection/5`'s `not shipping_required_here` clause
deliberately leaves it alone.

Reachable without anything exotic: pick a method at the checkout step, click
"Back", change the country to one that method does not serve, continue.

**Fix applied.** `enter_review/1` now delegates to
`reject_invalid_shipping_selection/1`, which under `:checkout` drops the
ineligible selection (`Shop.clear_cart_shipping/1`) and re-enters
`assign_shipping_step/1` — the step that owns the choice — with the methods for
the country the shopper just entered. Under `:cart` the `/cart` bounce is
unchanged, because there the cart page really is the picker. Clearing is not
optional: without it `assign_shipping_step/1` renders an unchecked list with
Continue still enabled, and Continue leads straight back into the same
rejection. Regression test: "editing billing to a country the chosen method does
not serve returns to the shipping step", which also drives the recovery through
to review.

### 2. [BUG - MEDIUM] Blocked shipping step has no exit — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` (`shipping_step/1`)
**Confidence:** 90/100

The third state of the step — nothing covers the country and `skip_mode` is
`off` — renders a warning and nothing else. No Continue (correct: the shop does
not deliver there) and no Back. The only remedy is a different address, which
lives on the previous step. The page-header link to `/cart` is not that remedy;
see issue 1.

**Fix applied.** A `.shipping_back_button` (rendered when `@needs_billing`) in
all three states. Test: "blocked shipping step still offers a way back to
billing".

### 3. [BUG - MEDIUM] `mix precommit` was red as merged — FIXED
**Files:** `lib/phoenix_kit_ecommerce/notifications.ex:154`,
`lib/phoenix_kit_ecommerce/ai_translatable.ex`,
`lib/phoenix_kit_ecommerce/web/product_form.ex`
**Confidence:** 100/100

The PR body says "`credo --strict` clean on the diff". Measured on the merge
commit:

- `mix credo --strict` → **exit 10**, 7 findings (2 nesting-depth in
  `ai_translatable.ex`, 5 nested-module-alias in `product_form.ex` and
  `ai_translatable_test.exs`).
- `mix dialyzer` → **exit 2**:

  ```
  lib/phoenix_kit_ecommerce/notifications.ex:154:22:call
  PhoenixKitEcommerce.Translations.get(%{:title => map()}, :title, binary())
  breaks the contract (:elixir.struct(), atom(), String.t()) :: any()
  ```

  `product_name/1` rebuilt a bare `%{title: title}` map to feed a function
  specced on `struct()`.

Both are in the undescribed half of the PR (issue 8), which is the likeliest
explanation for the claim: the gate was plausibly green on the precheckout work
alone and never re-run after the `phase4-catalog-ai` merge.

**Fix applied.** `product_name/1` passes the product struct through;
`ensure_prompt/0` and `merge_translation/3` each extracted one level;
`product_form.ex` aliases `AITranslate`/`FormGlue` **inside** the
`if @ai_translate?` block (a top-level alias would be evaluated in a
phoenix_kit_ai-less build too); the test aliases `Ecto.Adapters.SQL.Sandbox`.

### 4. [BUG - MEDIUM] Two settings with no way to set them — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/settings.ex`
**Confidence:** 100/100

`shop_shipping_skip_mode` and `shop_shipping_selection_position` are the
PR's headline feature. The settings page grew a card for the *notification*
toggles and nothing for these two. `rg` over `lib/` finds exactly one reader
each and no writer anywhere — the only way to turn the feature on was to write
the setting row by hand.

**Fix applied.** A "Shipping requirement" card (`#shop-shipping-modes-card`)
with radios for both, validated against closed enums in the `gated_event/3`
clauses — the readers fall back to the safe legacy value on anything they don't
recognise, so an unvalidated write reads as the setting being ignored, which is
why `update_catalog_vocabulary` validates too. The skip mode is audit-logged
(`shop.shipping_skip_mode_changed`): it decides whether an order can be placed
with no shipping method at all, which is exactly the setting an operator asks
"who changed this" about after a pending order appears. Tests:
`settings_shipping_modes_test.exs`.

### 5. [BUG - MEDIUM] Step indicator goes blank on `:shipping` — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` (`render/1`)
**Confidence:** 100/100

The indicator's three chips test `@step in [:payment, :billing, :review]` /
`[:billing, :review]` / `== :review`. On the new `:shipping` step none match, so
the shopper sees a progress bar with nothing highlighted at all — reading as
"you have gone backwards" at the step before payment.

**Fix applied.** `:shipping` added to the earlier chips' sets, plus a Shipping
chip rendered only on that step (only a checkout-position shop ever reaches it).

### 6. [BUG - MEDIUM] Continue accepts a method that is not on offer — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` (`shipping_step/1`)
**Confidence:** 85/100

`disabled={is_nil(@cart.shipping_method_uuid)}` asks "is anything selected",
not "is the selection one of the methods shown". A cart carrying a stale
selection from another country renders an all-unchecked list with Continue live.
Downstream (`shipping_selection_still_valid?/1`) catches it, which is what made
issue 1 a loop rather than a bad order — but the button should not offer the
move.

**Fix applied.** `disabled={not Enum.any?(@methods, &(&1.uuid == @cart.shipping_method_uuid))}`.

### 7. [BUG - MEDIUM] The shipping step can clear the cart's country — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/checkout_page.ex` (`assign_shipping_step/1`)
**Confidence:** 85/100

`Shop.set_cart_shipping_country(cart, billing_country(socket))` writes whatever
`billing_country/1` returns, including `nil`. The billing-less payment option
path (covered by the PR's own "mount alone" test) reaches this step with no
profile and no form data, so `billing_country/1` is `nil` — and the write
*clears* a country the cart may already have had, widening the method list back
to the country-blind one this step exists to avoid.

**Fix applied.** `apply_billing_country/2` only writes a non-empty binary.

### 8. [BUG - MEDIUM] Undisclosed scope, and a dependency the PR says it doesn't add — DOCUMENTED
**Files:** `mix.exs`, `ai_translatable.ex`, `seo_helpers.ex`, `product_form.ex`,
`catalog_product.ex`, `product.ex`
**Confidence:** 100/100

`git log f8bd6c9..5cb2617` shows the branch merged `phase4-catalog-ai`
(11 commits) before the precheckout work. That half is ~800 lines of `lib/`,
adds `pk_dep(:phoenix_kit_ai, "~> 0.17", optional: true)` to `mix.exs`, and
appears in neither the PR description ("No schema changes …, no dependency or
version changes") nor the CHANGELOG entry the PR wrote.

The code itself is sound — the optional-dep compile gate uses
`Code.ensure_compiled/1` rather than `ensure_loaded?/1` (the right choice, and
the comment says why), the adapter re-reads under `FOR UPDATE` and merges
against committed state, and it never trusts a model-supplied slug. It is the
*disclosure* that is the defect: a reviewer reading the PR body reviews half
the diff, and an operator reading the CHANGELOG on upgrade finds no mention of
a new dependency or a new admin surface.

**Not code-fixed** (the work is good and reverting it would be worse).
CHANGELOG entries written for both features and for the URL-language fix.

### 9. [BUG - MEDIUM] Recipient list is a snapshot, never re-checked — FIXED
**File:** `lib/phoenix_kit_ecommerce/notifications.ex` (`shop_recipients/0`)
**Confidence:** 80/100

The settings form validates each checked uuid against current
`shop.manage_carts` holders **at save time only**. `shop_recipients/0` then
filters the stored list on `is_binary/1` and nothing else. Revoke someone's shop
access and they keep receiving every cart-activity signal — and per AGENTS.md
the `shop.manage_carts` grant exists specifically because that surface carries
customer data. These messages carry what visitors are shopping for and what
their carts are worth.

**Fix applied.** The stored list is intersected with current holders on every
send. Fails closed: `admin_recipients/1` rescues to `[]`. Cost is three
permission queries per send on the every-add path, which is small next to the
per-recipient `Auth.get_user` + preference check `create_many/2` already does.
Test: "shop_recipients drops a stored uuid that is no longer a shop admin".

### 10. [BUG - LOW] `hreflang_links` is computed and thrown away — NOT FIXED
**Files:** `web/seo_helpers.ex`, `shop_catalog.ex`, `catalog_category.ex`,
`catalog_product.ex`
**Confidence:** 95/100

All four call sites `assign(:hreflang_links, …)`, and nothing anywhere renders
it — not this module, not core's root layout (which consumes `@og`, and emits
the canonical from `og[:url]`, but knows nothing about hreflang). `@canonical_url`
is likewise assigned and unread; it happens to be harmless because `og[:url]`
carries the same value.

So the hreflang half of "multi-domain SEO" — including the careful raw-slug-map
rule that is the file's best idea and has three tests — currently emits nothing.

**Deliberately not fixed.** `<link rel="alternate">` belongs in `<head>`, which
this module does not own: the storefront renders inside the HOST's layout
(AGENTS.md, "Storefront layout contract"). Making this real needs either a core
root-layout contract for `@hreflang_links` or a documented host hook, which is a
core-side change and out of scope for a post-merge fix. Recorded here so it is
not mistaken for working.

### 11. [OBSERVATION] German transliteration is not language-scoped
**File:** `lib/phoenix_kit_ecommerce/schemas/product.ex` (`slugify/1`)

`@german_translit` maps ä/ö/ü/ß → ae/oe/ue/ss for **every** language.
Estonian uses the same characters with different orthography: `Müük` becomes
`mueuek`, not `muuk`. The PR body calls this out and argues it is still a net
improvement over the previous behaviour (those characters were dropped
entirely: `m-k`), which is true.

Left as-is. The fuller fix is a per-language table, and the one caller with
language context (`AITranslatable.slug_base/3`) would have to thread it into a
changeset-time function that has none — a real change, not a patch.

### 12. [NITPICK] Two tests double-fire the notification they assert on
**File:** `test/phoenix_kit_ecommerce/notifications_test.exs:144,193`

`Shop.add_to_cart/3` calls `Notifications.cart_item_added/3` itself, so the
explicit `ShopNotifications.cart_item_added(cart, new_item, …)` that follows is
the second send. The assertions still hold, but the test would pass even if
`add_to_cart/3` stopped emitting the signal at all — which is the regression
worth pinning.

### 13. [NITPICK] `notify_event?/1` has no catch-all clause

`def notify_event?(event) when is_map_key(@notify_setting_keys, event)` raises
`FunctionClauseError` on a typo'd atom. Every caller is inside `safely/1`, which
swallows it and logs — so a mistyped event silently becomes "notifications off".
Left as-is: an internal API failing loudly on an unknown key is defensible, and
the two call sites are literals.

### 14. [OBSERVATION] `cart.items_count == item.quantity` as "first item"

`items_count` is total quantity, so the test is "this line is the whole cart" —
correct for a true first add. One drift case: a cart holding a single line
added while the toggle was off, then topped up after it is on, still reads as
"New cart started". The atomic flag means it can only mislabel once per cart,
and the PR's own "toggle flipped mid-lifecycle" test pins the multi-line case.
Not worth more machinery.

## What Was Done Well

- **The dedup primitive is the right one.** A single-statement conditional
  jsonb update, not a read-then-write, and a test that actually contends it.
- **`checkout_started` on connected mount only.** Crawlers and dead renders
  never claim the flag — the kind of thing that is obvious once stated and
  usually discovered in production.
- **Ordering discipline around the checkout country.** Three separate comments
  (`validate_cart_contents/1`, `validate_shipping_method_available/1`,
  `shipping_skippable?/1`) all say the same thing about the same invariant, and
  the code obeys it.
- **`calculate_shipping/3`, `product_name/1` and the billing-less path** were
  found by the author, not by review — all three are real, and the third is the
  subtle one.
- **Test-support extraction.** `checkout_fixtures.ex` deliberately builds the
  LiveView form payload from the same map the context-level test passes as
  `:billing_data`, so a required billing field cannot drift between the two.
- **The optional-dependency gate.** `Code.ensure_compiled/1` over
  `ensure_loaded?/1`, aliases scoped to the guarded block, a runtime
  availability flag on top of the compile flag, and no `@behaviour` on the
  adapter (which would have forced the dep). Correct on every axis.

## Gate

Run at `HEAD` after the fixes, with `phoenix_kit_ai` present:

| Step | Result |
|---|---|
| `mix format` | clean |
| `mix compile --warnings-as-errors` | clean |
| `mix credo --strict` | **no issues** (was exit 10) |
| `mix dialyzer` | **passed** (was exit 2) |
| `mix test` | 120 tests, 0 failures |
| `mix gettext.extract` | no drift |

⚠️ **No PostgreSQL in this environment**, so the 323 `:integration` tests —
which include every test this PR added and the four this review added — were
auto-excluded per the harness's design. The unit tier and the static gate are
green; the DB-backed tier needs a run where a database exists before release.

## Verdict

**Approved with fixes.** The two described features are correctly designed and
the invariant that matters most — never approve a total the conversion will
refuse — is enforced from both ends. The failures cluster in exactly one place:
`position: "checkout"` splits ownership of the shipping choice between two
pages, and the error paths were written for the world where the cart page owns
it. That produced one genuine dead-end loop (issue 1) and three smaller
navigation defects around the same step, all now fixed and covered.

Two things should not repeat. The gate was reported clean and was not
(issue 3) — `mix precommit` needs re-running after a merge, not before it. And
half the diff was undisclosed (issue 8): a PR body that describes two features
while shipping four, including a new dependency it explicitly denies adding,
is a review the repository did not actually get.
