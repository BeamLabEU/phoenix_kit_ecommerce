# Follow-up: PR #12 — Fix checkout security and wrong-money defects; add admin policy settings

Post-merge findings from `CLAUDE_REVIEW.md`, and the work the PR
deliberately left out.

## Resolved post-merge

| # | Severity | Finding | Where |
|---|---|---|---|
| 1 | BUG - HIGH | `get_price_range/3` kept all three pricing defects fixed in `calculate_final_price/4` — discounts dropped, no rounding, no zero floor. Storefront advertised the undiscounted price, and could render "From $-5.00". | `options/options.ex` |
| 2 | BUG - MEDIUM | Shopify `"Variant Price"` still truncated by the discarded `Decimal.parse/1` remainder; one mangled row set `base_price` for every variant. | `import/option_builder.ex` |
| 3 | BUG - MEDIUM | SSRF guard resolved IPv4 only, so IPv6-only image hosts were blocked outright, and a public-A/private-AAAA host was waved through. | `services/image_downloader.ex` |
| 4 | NITPICK | `Policy.legacy_cookie_window_open?/1` spec advertised `Date.t()`, which raises. | `policy.ex` |

Both pricing paths now share `apply_percent/2`; both importers now share
`PhoenixKitEcommerce.Import.Money.parse/1`. The new tests assert the two
paths **agree** rather than checking each against its own constant.

## Open

### 1. `shop_legacy_cookie_until` has no admin UI

`Policy` and `AGENTS.md` both state this is the one policy key where leaving
the default forever is wrong: unset means the pre-signing cookie adoption
window stays open, and it cannot self-close because nothing prunes carts
(`mark_abandoned_carts/1` only flips a status and is wired to no cron). The
settings page renders the other six keys and omits this one, so the only way
to close the window today is to write the setting from a console.

Adding the input is small; the cost is the i18n round-trip this module
requires (`mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy`,
plus hand-written ru and et). Left out as a feature addition rather than a
correction.

### 2. `private_host?/1` remains a TOCTOU check

The address is resolved for validation, then resolved again independently by
`Req`. A DNS record that answers public then private defeats it. Closing it
means resolving once and pinning the connection to the validated IP — a
transport-layer change. The guard raises the cost of the attack a long way
without eliminating it; it should not be described as complete.

### 3. Carried forward from the PR's own "deliberately not in this PR"

- **The test harness cannot express a denied scope.** `LiveCase.fake_scope/1`
  hardcodes `permissions: ["shop"]`, so no LiveView test can catch an authz
  regression. Unblocked by nothing — worth doing on its own.
- **The end-to-end admin-permission assertion belongs in a host app.** Core's
  resolver needs a running `ModuleRegistry`;
  `admin_permission_mapping_test.exs` pins what this repo can and says so.
- **Storefront i18n**: 8 LiveViews and all 5 components still have zero
  `gettext` calls.
- **The CSV import subsystem is largely untested.** `Options` pricing and the
  money parser now have suites; the 11 import modules around them do not.
  Note that two of the four defects found in this review were in that
  subsystem.
