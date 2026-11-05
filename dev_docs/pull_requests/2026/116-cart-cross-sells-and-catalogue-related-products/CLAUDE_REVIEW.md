# PR #116 — Add cross-sells to the cart and related products to catalogue items

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-29, `76a38ea`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`, after Codex's two
  fixes (`447c5db`)

## What was checked

- **Callers of the new `:cart_not_active` refusal.** `CatalogProduct` takes it in
  its generic error branch, `CartPage` shows its error flash, and `Errors.message/1`
  has a clause. `Claims.add_checked/7` turns it into `:busy`, and `CartWriter` already
  holds the row, so it cannot lose that race.
- **Stale offers.** `add_cross_sell` rebuilds the offers from a fresh cart before
  trusting the button. A missing cart reads as no offers rather than crashing.
- **Scoping.** `Query.list_items/1` resolves the shop catalogue itself, so the picker
  stays inside it without `with_catalogue/1`.
- **Lifecycle of `RelatedPicker`.** `ready?` keeps picks across re-renders, which is
  only safe if the host cannot switch items under it; `item_form_live.ex` has no
  `push_patch` or `patch=`.
- **Catalogue lines.** `line_product_uuid/1` reads the same
  `metadata["catalogue_item_uuid"]` the context writes, and a line whose product is
  gone drops out.

## Findings

### BUG - MEDIUM — the catalogue picker offered deleted items and showed raw statuses (fixed)

`search_rows/4` called `Query.list_items/1` with no status, so items in the
catalogue's trash (`status: "deleted"`) were offered. A merchant could fill a slot of
twelve with something shoppers never see, and the card's hint only warns about drafts
and hidden products. The row's `sublabel` was the raw `item.status`, which AGENTS.md
forbids, and it answered the wrong question: `item.status` has no draft, so a shop
draft read "active". The Legacy picker already used `StatusLabels.product/1`.

The search now passes `exclude_deleted: true` (a new `Query` filter, applied before
the limit), and the label is `StatusLabels.product(View.product_status(item, ecommerce))`.

The picker still allows drafts on purpose, like the Legacy one. An item deleted
*after* it was picked keeps its chip until removed: the storefront skips it, and the
pick survives a restore from the trash.

The new test failed before the fix, returning the deleted item and raw values.

### NITPICK — the product page never passes `language:` (left open)

`RelatedProducts.for_product/2` documents `:language`, and the three call sites in
`CatalogProduct` omit it, while the cart passes it. It changes nothing a shopper sees
today: on the catalogue source the option only picks option-value labels, and the
card reads titles and URLs from the view's language maps. No test could tell the
difference, so it is recorded rather than changed.

### NITPICK — `RelatedPicker` events are not permission-gated (left open)

`ProductForm` re-checks `manage_catalog` on each picker event; the LiveComponent
cannot, since it has no scope and no assign reaches it from the catalogue's form. It
writes nothing itself: picks stage into hidden inputs, the catalogue's own save is
the write, and search shows only items the form's user can already see.

Validation is in [FOLLOW_UP.md](FOLLOW_UP.md).
