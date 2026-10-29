# PR #116 — cart cross-sells and catalogue related products

Reviewed 2026-10-29 against merge `76a38ea`.
Author: Tymofii Shapovalov (`timujinne`).
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/116

Compared the recent merged PRs with the existing Codex review records:
#109–115 already have reviews; #116 is the new unreviewed merge. Applied
the Phoenix and Ecto thinking skills. Read the changes and surrounding
cart, pricing, option, visibility, catalogue extension and form code,
including the installed catalogue's extension absorption and parent form.

## BUG - MEDIUM: Add trusts offers and quick-add eligibility from an old render

`CartPage` looked up the submitted UUID in its assigned offers and checked
the assigned quick-add set. Product/category changes do not reach the cart's
PubSub subscription. As a result, an old button could add a product after
the merchant removed its offer, hid its category, or the availability hook
began refusing it. Adding an optional choice after render also allowed a
quick add without giving the buyer that choice; context validation accepts
omitting an optional option. Deleting an offered Legacy product instead
raised `Ecto.NoResultsError` inside `lock_or_reload_product/2`, crashing the
cart page.

Fixed by reloading the originating cart and rebuilding its offers before
resolving the UUID and quick-add eligibility. This reuses both sources'
listed-product queries and the existing availability and option readers.
The destination remains the shopper's active cart, including a new cart
when the originating cart has already been converted.

Five new Legacy regressions reproduced all five failures before the fix.
An additional catalogue regression checks a category hidden after render.
The existing test of adding from a page left open across checkout still
passes.

## BUG - HIGH: the active-cart lookup does not serialize Add with checkout

The new handler re-fetches the active cart before calling `add_to_cart`, but
checkout can convert that cart after the read and before the line write.
Both context add paths locked the product, then inserted/incremented a line;
they acquired a cart lock only while recalculating totals and never
rechecked its status. An add could therefore change an already converted
cart after its order had snapshotted the lines. This context gap predates
the PR; the new cross-sell button exposes it despite its active-cart check.

Fixed both context paths to lock and reload the active cart after the
product's locked/fresh read and option validation, before touching a line.
This uses the existing `lock_active_cart!/1` and product-then-cart order.
An inactive row rolls the transaction back with `{:error, :cart_not_active}`;
the handler already renders an error for this result. Reloading also keeps
the subsequent totals calculation on the current cart fields.

Four new tests cover both simple and selected-option adds. Two exercise
stale caller structs and verify neither insertion nor quantity increment
can change a converted cart. Two use committed data and separate real
connections: one transaction changes the cart to converted and holds its
row; the add waits, then must refuse the newly committed status. All four
failed against the previous context and pass with the fix.

## Validation and limits

Final validation is recorded in [FOLLOW_UP.md](FOLLOW_UP.md).

No additional finding in list normalization, metadata ownership, hidden
sentinels for clearing lists, picker event routing/pagination, category
preloads, source visibility filtering, or localized storefront rendering.
The engineering guide now describes offer refresh and the cart lock boundary.

The offer refresh is a fresh read, not a reservation against concurrent
catalogue/category/availability changes. The existing pricing transaction
continues to validate the fresh product's status and required options.
Catalogue reads remain unlocked, as documented by `lock_or_reload_product/2`.

No dependency change, migration, version bump, CHANGELOG entry or release.
