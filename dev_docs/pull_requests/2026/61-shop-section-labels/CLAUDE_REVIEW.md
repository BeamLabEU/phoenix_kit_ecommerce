# PR #61 — Match the catalogue's labels and wording in the shop section

- **Author:** Max Don
- **Merged:** 2026-09-20, `343d585` on `main`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`

Reviewed late: the directory had Grok's review and a follow-up but no Claude
review. Read against the current tree, not the tree of the merge.

## What was checked

- **Grok's two findings stay fixed.** No `.po` under `priv/gettext/` carries a
  `fuzzy` flag (six catalogues, zero matches), and the form prompt is
  `gettext("— Category not set —")` (`web/product_form.ex:1038`).
- **The `.fieldset` wrappers stay gone.** `catalogue/shop_sections.ex` has none,
  including the `RelatedPicker` block #116 later added to the same section.
- **The product page's "No category" is unchanged.** `web/product_detail.ex:551`
  states a fact about the product, so it correctly kept its wording.

## Findings

None.
