# PR #115 — Add hand-picked related products: form card, product page block and settings

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-29, `26ea4bf`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`, after Codex's four
  fixes

## What was checked

- **Stored data is treated as untrusted.** Every reader goes through
  `RelatedProducts.normalize/2`. The 36-byte check stops `Ecto.UUID.cast/1` taking a
  raw 16-byte string, and malformed values read as an empty list.
- **Visibility.** `list_listed_by_ids/1` and `list_listed_in_category/3` filter on
  `active` and on the hidden-category subquery #111 introduced, and preload the
  category `ShopCards.product_card` reads. The merchant's order survives the
  `Map.new` round trip.
- **Metadata ownership.** Both keys are in `@form_owned_metadata_keys`, and
  `put_related/2` deletes a key when its list empties, so a list can be cleared and
  the form's merge keeps every other key.
- **The catch-all added to `ProductForm`.** It comes after the last clause and
  shadows nothing. The AI-translate events arrive through an `on_mount` hook, so they
  never reach it.
- **Availability hook.** `catch kind, reason` covers raises, exits and throws. A
  broken hook is logged and counts as available.
- **Settings.** Both handlers are gated and audited, and the limit is range-checked
  on write and on read. All six catalogues carry the new strings.

## Findings

None beyond Codex's. See [the #116 review](../116-cart-cross-sells-and-catalogue-related-products/CLAUDE_REVIEW.md)
for the catalogue side of the same feature.
