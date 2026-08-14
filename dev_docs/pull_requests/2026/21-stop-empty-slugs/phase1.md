# PR #21 Phase 1 Review — phoenix_kit_ecommerce

**Title:** Stop writing empty slugs that lock a shop out of its own index
**Author:** Max Don (mdon)
**Date:** 2026-08-14
**Verdict:** APPROVE WITH NOTES

---

## Summary

Fixes a real, reproducible production bug: `Slug.slugify/2` silently returns `""`
for scripts it cannot romanize (CJK, Arabic, emoji), and the unique index
`extract_primary_slug(slug)` is partial on `IS NOT NULL` only — so a written `""`
was enforced, and the _second_ product with an unromanizable title could not be
inserted (`duplicate key value violates unique constraint`).

The fix is local and self-contained: both `Product` and `Category` get an
extracted `put_generated_slug/2` helper that guards the _result_ of `slugify/2`
(not just the input), plus a trailing `Enum.reject` pass that scrubs pre-existing
`""` values from the slug map. Legacy rows self-heal on their next changeset save
without a migration. PR says it is intentionally independent of the
`put_slug/3` core series and carries its own test suite (5 regression tests).

**Stats:** +129 / -16 across 3 files. No migration. No version bump. No CHANGELOG entry.

---

## Findings

### Blockers

**None.** The fix is correct and the tests are solid. However the two items below
must land before a Hex release can be cut.

### Non-blockers

1. **Missing `@version` bump and CHANGELOG entry** — PR body explicitly says
   "No `CHANGELOG.md`, no `@version`." Both are required before publishing to
   Hex. Current version is `0.2.1`; this warrants at minimum a patch bump to
   `0.2.2`. CHANGELOG needs a `### Fixed` entry describing the empty-slug bug.
   _Will block Hex publish, not the merge itself._

2. **No migration for currently-locked shops** — The self-heal approach is valid
   and documented, but shops that _already_ have `{"en": ""}` slugs in production
   are still unable to insert new products until some save event clears the
   poisoned row. A one-off migration that runs
   `UPDATE shop_products SET slug = slug - '<lang>' WHERE slug->>'<lang>' = ''`
   (or equivalent) would give immediate relief. The PR explicitly defers this,
   so it is a conscious decision — worth flagging to Dmitri if we have known
   affected tenants.

3. **Duplicate `put_generated_slug/2`** — Identical private function defined in
   both `Product` and `Category`. Once this lands, worth extracting into a shared
   helper (e.g. `PhoenixKitEcommerce.Slug` or a `SlugHelpers` module). Not
   urgent, just accumulating duplication.

### Nitpicks

- The inline comments in `product.ex` and `category.ex` are unusually long (8+
  lines explaining the bug). They're accurate, but that explanation belongs in
  the commit message / PR body, not the source. Could be trimmed post-merge.
- `put_generated_slug(&2, &1)` argument inversion in `Enum.reduce/3` is correct
  but slightly non-obvious; a named `fn acc, kv -> put_generated_slug(acc, kv) end`
  reads more clearly.

---

## Technical correctness

| Check | Result |
|-------|--------|
| Guards result of `slugify/2`, not just input | ✅ |
| Scrubs pre-existing `""` values (self-heal) | ✅ |
| `put_generated_slug/2` arg order vs `Enum.reduce` | ✅ correct |
| Final `Enum.reject … Map.new()` doesn't clobber valid slugs | ✅ |
| No migration needed for fix itself | ✅ |
| Independent of unreleased `put_slug/3` core feature | ✅ |

---

## Stats

- **Tests:** 5 new regression tests in `test/phoenix_kit_ecommerce/empty_slug_test.exs`
  (unit-level changeset tests + 2 DB-level integration tests against the real index)
- **Migrations:** None (by design — self-heal on save)
- **Version bump:** ❌ Missing — needed before Hex publish
- **CHANGELOG entry:** ❌ Missing — needed before Hex publish
- **Dependency changes:** None (no phoenix_kit version change required)
