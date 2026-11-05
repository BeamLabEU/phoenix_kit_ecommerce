# PR #113 — Add settings to hide the catalog sidebar and show categories as buttons

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-29, `851f31a`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`

## What was checked

- **Defaults keep the old markup.** `products_grid_class/2` keeps each page's own
  token order when the sidebar is on, and `sidebar_helper_class(true, _)` keeps
  `lg:hidden`.
- **Categories and filters stay reachable.** With the sidebar off, the toggle and
  the drawer lose `lg:hidden`. With `shop_sidebar_show_categories` off on the shop
  page, `@category_chips?` is false, so `category_nav` still renders. Every
  combination of the three settings leaves a way to a category.
- **Links.** `category_chips/1` builds its links with `Shop.catalog_url/1` and
  `Shop.category_url/2` plus `@filter_qs`, as `category_nav/1` does, and a false
  `aria-current` is dropped from the output.
- **Stored values.** The handler accepts only `cards` and `buttons`, and
  `Helpers.category_display/0` reads anything else as `"cards"`. Both handlers are
  gated and audited. `Vocabulary.all_items/0` supplies the translated first label.
- **Other pages.** Only the two catalog pages use this layout. The product page's
  category card follows `shop_sidebar_show_categories`, as it did before.

## Findings

### NITPICK — buttons and the sidebar's category list show together on desktop (left open)

With `shop_category_display: "buttons"` and the sidebar on, a desktop visitor gets
the row of buttons and the sidebar's category list on the same page. The code
comment only says the buttons replace the phone list, so this reads as a choice
rather than a slip, and hiding one would need a third rule for the same two
settings. Worth a look from whoever owns the storefront's design.
