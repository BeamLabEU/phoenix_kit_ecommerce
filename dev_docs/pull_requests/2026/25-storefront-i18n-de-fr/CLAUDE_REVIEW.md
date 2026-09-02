# Code Review: PR #25 — i18n: German and French storefront translations + localize filter labels

**Reviewed:** 2026-09-02
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/25
**Author:** Tymofii Shapovalov (timujeen)
**Head SHA:** 82f379e7e81770d9fd97bfd420f6d1f74592a6d2 (squash-merged onto `main`)
**Status:** Merged

## Summary

Adds complete `de` and `fr` gettext catalogues for the storefront (782
msgids each, 0 untranslated, additive — `en`/`et`/`ru` and every source
msgid untouched), and makes the storefront filter sidebar translate its
*built-in* filter labels at render time.

The filter-label change went through two self-corrections in the PR's own
history, both correct: first it ran every filter's stored `label` through
Gettext by string alone (which would silently rewrite an admin's own copy
whenever it collided with an unrelated msgid), then it narrowed to a
`{key, label}` pair match against `Shop.default_storefront_filters/0`, so a
renamed built-in or any custom metadata filter renders verbatim. It also
found and fixed six `fr` `msgstr[0]` entries with a hardcoded `1` — French's
CLDR rule sends `n=0` to the *singular* index, so an empty French cart read
"1 article".

## Issues Found

### 1. [BUG - MEDIUM] The `ru` and `et` catalogues duplicate the count on `item`/`items` — FIXED
**File:** `priv/gettext/ru/LC_MESSAGES/default.po` (msgid `"item"`),
`priv/gettext/et/LC_MESSAGES/default.po` (same msgid)
**Confidence:** 100/100

This PR audited plural entries in the two catalogues it was adding and
correctly reported them clean. The audit stopped there, and the same class
of bug it had just fixed in `fr` is sitting in the two catalogues that were
already shipping.

The call site (`web/user_orders.html.heex:93`) renders the count *itself*
and then calls `ngettext` for the noun alone:

```heex
{items_count(order.line_items)} {ngettext("item", "items", items_count(order.line_items))}
```

so the msgstrs must carry the noun only — which is what the `de` and `fr`
entries this PR added correctly do (`"Artikel"`, `"article"`). `ru` and `et`
instead carry the count as well:

```po
msgid "item"
msgid_plural "items"
msgstr[0] "%{count} позиция"     # ru — ngettext/3 supplies %{count} automatically
msgstr[1] "%{count} позиции"
msgstr[2] "%{count} позиций"
```

`ngettext/3` binds `%{count}` implicitly, so a Russian user's order list
reads **"3 3 позиции"**. `et` has both halves of the problem in one entry:
`msgstr[0]` is `"1 ese"` (the hardcoded-`1` bug this PR fixed in `fr`) and
`msgstr[1]` is `"%{count} eset"` (the duplication), rendering **"1 1 ese"**
and **"3 3 eset"**.

Fixed: both reduced to the bare noun, matching `de`/`fr`. The adjacent
`"1 item"` / `"%{count} items"` msgid — a *different* entry whose msgid_plural
does carry the token — is untouched and still correct.

### 2. [OBSERVATION] `et` and `ru` render the "Vendor" facet as "supplier" — NOT FIXED, deliberate
**File:** `priv/gettext/{et,ru}/LC_MESSAGES/default.po` (msgid `"Vendor"`)
**Confidence:** 80/100

The PR's fourth commit corrected `fr` "Vendor" from `Fournisseur`
(supply-chain "supplier") to `Vendeur`, reasoning that the storefront facet
and the product-detail `Vendor:` label are customer-facing. That reasoning
applies equally to `et` `"Tarnija"` and `ru` `"Поставщик"`, which are both
the supplier sense.

Deliberately not changed. `fr` was brand-new in this PR — no installed shop
had ever rendered it — whereas `et` and `ru` are what live trilingual shops
have been showing customers for months. Silently rewriting established
customer-facing copy in a patch release is a bigger change than the wording
is worth, and the right replacement is a merchandising decision (Shopify's
`vendor` field is in practice the brand/manufacturer, so "Бренд" /
"Производitель" may beat a literal "Продавец"). Flagged for the operator to
decide; the msgid is one entry per locale if they want it.

### 3. [NITPICK] `builtin_labels/0` is rebuilt on every `translate_label/1` call
**File:** `lib/phoenix_kit_ecommerce/web/components/catalog_sidebar.ex:373-375`
**Confidence:** 95/100

`for f <- Shop.default_storefront_filters(), do: {f["key"], f["label"]}`
allocates three maps and a two-tuple list per filter section per render.
Immaterial at three filters, and hoisting it to a module attribute would
freeze another module's function result at compile time — a worse trade.
Left as-is.

## What Was Done Well

- **The self-correction on `translate_label/1` is the right call, for the
  right reason.** Translating an admin-entered string by string match is a
  data-rewriting bug that gets *worse* with every msgid a later release adds,
  and the `{key, label}` pair check is the narrowest rule that still
  localizes the built-ins. The commit message states that widening
  collision set explicitly.
- **The `fr` `n=0` fix is a genuine find**, and the accompanying
  `dngettext` fixtures at n=0/1/2 in `i18n_test.exs` pin exactly the case a
  smoke test at n=1 cannot distinguish from correct.
- **The test for a custom filter renamed to a built-in's label**
  (`msrp` → labeled `"Price"`) is the case that separates a `{key, label}`
  check from a label-only one; the PR notes it confirmed the mutation fails
  the suite.
- Mechanical audit of both new catalogues comes back clean: 0 empty
  msgstr, 0 interpolation-token mismatches, correct `Plural-Forms` headers
  for both (`de`: `n != 1`; `fr`: `n > 1`).

## Verdict

**Approved with fixes.** The PR's own work is sound and its two rounds of
self-review caught real problems. One fix applied: the plural-catalogue bug
this PR fixed in `fr` also exists, unaudited, in `ru` and `et`.
