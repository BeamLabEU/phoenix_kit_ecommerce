# PR #112 — Add a shop setting to require a phone number at checkout

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-29, `bcd67c4`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`, after Codex's two
  fixes

## What was checked

- **Enforced in the context, not only the form.** `validate_billing_completeness/2`
  sits inside `convert_cart_to_order/2`, the one conversion path (`CheckoutPage`
  is its only caller in `lib/` apart from the deprecated delegate), so a crafted
  `confirm_order` cannot skip it. Saved profiles and typed details are both covered.
- **Non-text values.** After Codex's fix `validate_billing_data_completeness/3`
  takes only nonblank text, so `"phone" => false` is refused.
- **Recovery.** `{:billing_incomplete, missing}` sends the shopper to an editable
  billing step whose form is rebuilt with the requirement, prefilled from a saved
  profile when that was the source. `billing_incomplete_message/2` handles the
  `["billing details"]` value the context can also return.
- **Billing compatibility.** `BillingSupport.declares_require_phone?/1` reads
  `__components__/0`, so billing 0.24.0 (no attribute) gets no unknown-attribute
  warning. Billing `main` declares `require_phone` on the component and in
  `fields_changeset/3`, the two places the moduledoc names. Passing the option to
  0.24.0's changeset is harmless because it reads options by key.
- **Settings.** The toggle goes through `Authz.authorize/3` and logs on `{:ok, _}`
  with no PII; the key is listed in the guide and the README.

## Findings

None beyond Codex's.

`require_phone_at_checkout?/0` answers `false` on a settings error, where
AGENTS.md says policy readers fail closed. That is right here: the rule protects
security policy, its `@doc` states the choice, and failing closed would refuse every
order during a settings outage to collect an optional field.
