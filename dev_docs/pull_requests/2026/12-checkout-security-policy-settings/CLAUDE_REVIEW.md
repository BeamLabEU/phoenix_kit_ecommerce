# Code Review: PR #12 — Fix checkout security and wrong-money defects; add admin policy settings

**Reviewed:** 2026-08-04
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/12
**Author:** Max Don (mdon)
**Head SHA:** 68033839582b7b9db6dbd5da445fd9f27ce1f1d3
**Status:** Merged

## Summary

A large security and correctness sweep over checkout: billing-profile IDOR,
world-readable order confirmation pages, guest cart takeover on a shared
browser, stored XSS on the storefront, SSRF in the CSV image importer,
non-active products being publicly purchasable, and a set of wrong-money
defects (tax never charged, then charged on non-taxable lines, then charged
above the amount the customer approved; truncated CSV prices; free shipping
via an outgrown method; lost cart totals under concurrency). Seven policy
keys were introduced behind a single `PhoenixKitEcommerce.Policy` module so
the admin UI and the enforcement points share one definition of each
default, and each reader fails closed.

The work is careful and unusually well evidenced — findings were reproduced
before being fixed, an earlier consensus claim about admin authorization was
retracted after being disproved, and the upgrade-compat paths (cookie
signing, pre-existing orders, pre-existing carts) were each thought through
rather than assumed away.

The defects below are all of one shape: **a rule fixed in one place and left
standing in its sibling.** Every one was reproduced by running the shipped
code before being fixed.

## Issues Found

### 1. [BUG - HIGH] `get_price_range/3` kept all three pricing defects that were fixed in `calculate_final_price/4` — FIXED

**File:** `lib/phoenix_kit_ecommerce/options/options.ex` lines 1242-1266 (pre-fix)
**Confidence:** 100/100 — reproduced against the merged code

The PR's own headline pricing fix — "percentage discounts did nothing",
"fixed-only prices were never rounded", "modifiers that invert the price
should floor at zero" — was applied to `calculate_final_price/4` only. Its
sibling `get_price_range/3` carried a second, independent copy of the same
arithmetic and kept **all three** bugs, including the identical
`Decimal.compare(percent, 0) == :gt` gate the commit message calls out by
name.

This is the more customer-visible of the two functions: it feeds
`Shop.get_price_range/1`, `Shop.format_price_range/1`, `product_detail.ex`
and `product_form.ex` — the storefront's "From $X".

Reproduced on the merged code:

| Specs | `get_price_range/3` said | Actually charged |
|---|---|---|
| `{Standard 0%, Sale -20%}`, base 100 | `{100, 100}` | `80.00` |
| `{a 0, b +0.005}`, base 10.00 | `{10.00, 10.005}` | `10.01` |
| `{a 0, b -15}`, base 10.00 | `{-5.00, 10.00}` | `0.00` |

So a shop running a percentage sale advertised the undiscounted price; a
price range could carry more precision than the `DECIMAL(12,2)` column it is
compared against; and a large enough fixed discount rendered a literal
**"From $-5.00"** on the storefront.

The PR's new `get_price_range/3` test only exercised **fixed** modifiers, so
the percent branch — the one that was wrong — was never executed.

**Fix applied:** the percent-apply / round / floor sequence is now a single
private `apply_percent/2` that both functions call, so the two cannot drift
again. The range's two ends are additionally ordered numerically, because a
multiplier below `-100%` inverts them. Three tests added to
`options_pricing_test.exs`, each asserting the range end **equals** what
`calculate_final_price/4` returns for the corresponding selection — pinning
the agreement rather than two independent constants.

### 2. [BUG - MEDIUM] The Shopify variant path still truncated prices — FIXED

**File:** `lib/phoenix_kit_ecommerce/import/option_builder.ex` lines 234-241 (pre-fix)
**Confidence:** 100/100 — reproduced against the merged code

The PR fixed the `Decimal.parse/1` remainder-discarding defect (`"12,50"` →
`12`) in `PromUaFormat`, and hardened it thoroughly. `OptionBuilder`, which
parses Shopify's `"Variant Price"`, kept the original
`case Decimal.parse(str) do {decimal, _} ->` unchanged.

Reproduced: variant rows priced `"12,50"` and `"1,234.56"` produced
`base_price = Decimal.new("1")`. Because `base_price` is the **minimum**
variant price, a single mangled row sets the price for every variant of the
product — and, as the PR notes for the other importer, nothing errors. The
product simply goes on sale for a fraction of its price.

Shopify's canonical export uses dot decimals, which is why this survived;
a feed re-exported or hand-edited in a comma-decimal locale is the exposure.

**Fix applied:** the parser was extracted, unchanged, into
`PhoenixKitEcommerce.Import.Money.parse/1` — one implementation for every
import format. `PromUaFormat.parse_money/1` now delegates to it (preserving
the public name the regression suite asserts against), and
`OptionBuilder.parse_price/1` calls it. Three tests added covering decimal
comma, thousands separator, and an unreadable cell being dropped rather than
treated as free.

### 3. [BUG - MEDIUM] The SSRF guard blocked every IPv6-only image host — FIXED

**File:** `lib/phoenix_kit_ecommerce/services/image_downloader.ex` lines 361-368 (pre-fix)
**Confidence:** 95/100

`private_host?/1` resolved names with `:inet.getaddrs(host, :inet)` — IPv4
only. For a host with only AAAA records that returns `{:error, :nxdomain}`,
which the fail-closed branch correctly reads as "unresolvable" and blocks.
The result is that image import from any IPv6-only CDN fails, and the guard
rather than the network is what stops it. Before this PR there was no guard
at all, so this is a regression introduced by the fix.

The same gap cut the other way: a host with a **public A record and a
private AAAA record** was waved through, because only the family the
resolver happened to be asked for was inspected.

**Fix applied:** both families are resolved and the host is blocked if any
answer is private; only a name that resolves in neither is treated as
unvouchable. This is strictly safer than the single-family check as well as
strictly more permissive for legitimate v6 hosts. A test pins real v6
classification (`fd00::1`, `fe80::1` blocked; `2001:4860:4860::8888`
allowed) — these clauses existed but were previously reachable only via
unfolded v4-mapped addresses.

### 4. [NITPICK] `Policy.legacy_cookie_window_open?/1` advertised an argument that crashes it — FIXED

**File:** `lib/phoenix_kit_ecommerce/policy.ex` line 136 (pre-fix)
**Confidence:** 100/100

`@spec legacy_cookie_window_open?(Date.t() | DateTime.t())`, but
`parse_cutoff/2` compares with `DateTime.compare/2`, which raises on a
`Date`. No caller passes one — the default is `DateTime.utc_now()` — so this
is documentation pointing at a crash rather than a live bug. Spec narrowed
to `DateTime.t()`.

### 5. [OBSERVATION] `shop_legacy_cookie_until` has no admin UI — NOT FIXED

**File:** `lib/phoenix_kit_ecommerce/web/settings.ex`
**Confidence:** 100/100

`AGENTS.md` and `Policy`'s own moduledoc are explicit that this is "the one
setting here where leaving the default forever is the wrong choice" — unset
means the pre-signing cookie adoption window never closes, and the adoption
criterion cannot self-expire because nothing prunes carts. The settings page
renders the other six policy keys and omits this one, so the only way to
close the window is to write the setting from a console.

**Deliberately not fixed here.** Adding the input is small, but it is a new
user-facing string in a module whose i18n contract requires
`mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy` plus
hand-written ru and et translations — a feature addition rather than a
correction to what this PR got wrong. Recorded in `FOLLOW_UP.md` so it is
findable.

### 6. [OBSERVATION] `private_host?/1` is a TOCTOU check — NOT FIXED

**File:** `lib/phoenix_kit_ecommerce/services/image_downloader.ex`

The address is resolved for validation and then resolved again, independently,
by `Req`. A DNS entry that answers public on the first lookup and private on
the second defeats the guard. Closing it properly means resolving once and
pinning the connection to the validated IP, which is a transport-layer change
well beyond this PR. Worth stating explicitly so the guard is not mistaken for
a complete defence; it raises the cost of the attack substantially without
eliminating it.

## What Was Done Well

- **Findings were reproduced, not inferred.** The retraction of the
  admin-authz claim — including running core's resolver to disprove a
  4-of-5 review consensus — is the right instinct, and the replacement
  test's moduledoc is honest about what it *cannot* assert from this repo.
- **`Policy` as a single source of truth.** Every reader fails closed on a
  settings-layer error, and the "genuine invariants get no setting" line is
  the right boundary — billing-profile ownership is enforced, not
  configurable.
- **Defence in depth at the right layer.** `validate_billing_profile_owner/2`
  in the context, not only in the LiveView, because
  `convert_cart_to_order/2` is public and re-exported. Same reasoning for
  deriving `placing_session_id` internally rather than accepting it from
  `opts`.
- **Lock ordering was reasoned about, not stumbled into.** Taking the cart
  lock in `recalculate_cart_totals!/1` rather than in each of eight callers,
  with the explanation of *why* the position matters, plus an explicit
  no-ABBA note.
- **Upgrade compatibility was treated as a correctness requirement.** Cookie
  signing, order access tightening and cart re-keying would each have
  silently broken deployed shops; all three carry a migration path, and the
  legacy adoption path mints a *fresh* id rather than re-signing the client's
  value — which is the difference between delaying the capability by one
  request and removing it.
- **`maybe_send_guest_confirmation/1` moved outside the transaction**, so an
  SMTP failure can no longer roll back a paid order.
- Comments explain *why* and cite the concrete failing case. This review was
  materially faster because of them.

## Verdict

**Approved with fixes.** The security work is sound and the reasoning behind
it is documented to an unusually high standard. Every defect found was the
same failure mode — a correct fix applied to one of two places that had to
agree — which is exactly what a second pass is for, and is a consequence of
the sweep's breadth rather than of carelessness. The pricing one (#1) was
live and customer-visible on the storefront's advertised prices.

The three code fixes are now expressed as *shared* code (`apply_percent/2`,
`Import.Money`) rather than as parallel corrections, so the same drift
cannot recur silently, and the new tests assert the two paths **agree**
rather than checking each against a constant.

Gate: `mix precommit` — format, `compile --warnings-as-errors`,
`deps.unlock --check-unused`, `hex.audit`, `credo --strict`, dialyzer — exit
0. Test suite: 94 unit tests passing (integration tests auto-excluded, no
PostgreSQL in this environment, per the harness's documented two-tier
stance).
