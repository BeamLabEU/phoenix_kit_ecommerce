# Code Review: PR #29 — AI translation: shape product slugs from the title head, add regenerate_slug/3

**Reviewed:** 2026-09-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/29
**Author:** Tymofii Shapovalov (timujeen)
**Head SHA:** 18dc12650df169e695f750c0b7f1478cb31767bf
**Status:** Merged

## Summary

`slug_base/3` slugified the whole translated title — SEO segments included —
and hard-cut it at 80 characters, landing mid-word and making near-identical
prefixes collide. It now takes the first segment before a `|` or a spaced dash,
falls back to the full title when that head slugifies to `""`, caps at 60 on a
word boundary, and carries the default-language slug's numeric identity tail
(`-<4+ digits>`, e.g. an imported Shopify id). A public `regenerate_slug/3` is
added as an explicit one-off repair path that recomputes a language's slug even
when one exists, with `dry_run: true` for previewing.

The core string logic is sound. I traced `cap_word_boundary/2` through every
branch — the exact-boundary case (`String.at(slug, max_len) == "-"`), the
no-separator hard cut, and the drop-the-partial-word path all behave as
documented, and none can return `""`. The 4-or-more-digit rule for the identity
tail correctly refuses to mistake `unique_slug/3`'s own `-2`/`-3` collision
suffixes for a Shopify id, and the second commit's `strip_identity_tail/1` on
the borrowed fallback slug is the right place to keep `with_identity_tail/2` the
single appender. `Product.slugify/2` is guaranteed to return a binary (core's
`PhoenixKit.Utils.Slug` passes `fallback: :empty`), so the new pipeline can never
be handed `nil`.

## Issues Found

### 1. [BUG - MEDIUM] A projected slug collision raises `Ecto.ConstraintError` instead of returning an error — FIXED
**File:** `lib/phoenix_kit_ecommerce/ai_translatable.ex` lines 213-216 and 246-249 (pre-fix)
**Confidence:** 100/100 — reproduced with a test that raises without the fix

Both write paths build their changeset with `Ecto.Changeset.change/2`:

```elixir
case fresh |> Ecto.Changeset.change(changes) |> repo().update() do
```

which bypasses `Product.changeset/2` and therefore its
`unique_constraint(:slug, name: "phoenix_kit_shop_product_slugs_pkey")`. V171's
projection trigger inserts `(base language, value, owner)` rows and the pkey
*is* the uniqueness constraint, so a colliding slug raises a
`Postgrex.Error`/`Ecto.ConstraintError` out of `repo().transaction/1` rather
than coming back as `{:error, changeset}` — crashing the AI translation job
instead of failing it cleanly.

`unique_slug/3` is supposed to prevent that, but its pre-check does not mirror
the database's bucket (see finding 2), and it is a check-then-write with the row
lock held only on the product being written, so two products translated
concurrently to the same slug both pass it.

Pre-existing in `write_merged/3`, but this PR is where it matters: the new
head-only slugs are materially shorter and less distinctive (`"Vase en Bois |
Decoration"` and `"Vase en Bois | Cadeau"` now both reduce to `vase-en-bois`),
so cross-product collisions go from rare to routine — and
`write_regenerated_slug/5` repeats the same pattern in new code.

**Fix applied:** both paths now go through a shared `slug_changeset/2` that
registers the projection pkey by name, so a collision returns
`{:error, %Ecto.Changeset{}}`. Regression test added
(`"a projected slug collision comes back as a changeset error, not a raise"`),
which raises `Ecto.ConstraintError` with the constraint removed.

### 2. [OBSERVATION] `unique_slug/3` checks the exact jsonb key; the constraint buckets by base language — not fixed

```elixir
where: fragment("?->>? = ?", p.slug, ^lang, ^candidate)
```

matches the literal language key, while core's trigger projects
`lower(split_part(key, '-', 1))` — `en-US` and `en` share one bucket. A product
holding `{"en" => "vase"}` is therefore invisible to a `unique_slug/3` call for
`"en-US"`, and the collision only surfaces at insert time. That is what the
regression test in finding 1 exercises.

Deliberately **not** fixed: mirroring the fold here means duplicating core's
bucketing rule in this module, where it would silently drift the next time core
changes it — the exact class of two-lists-out-of-sync bug that produced the
V52-era expression index this projection replaced. With the constraint now named,
the mismatch degrades to a clean changeset error instead of a crash, which is the
right failure mode for a rule the database owns. Recorded here so the limitation
is on file.

### 3. [OBSERVATION] `regenerate_slug/3` writes no activity entry

`put_translation/4` calls `log_translated/3`; the new repair path broadcasts
`Events.broadcast_product_updated/1` but logs nothing. Changing a slug rewrites a
public URL, which is arguably the most audit-worthy write in this module. Not
changed here: `regenerate_slug/3` takes no actor and `Activity` wants a scope, so
adding one means changing the signature the PR just introduced. Worth doing when
the bulk repair task that motivated this function lands, since that task will
have an actor.

### 4. [OBSERVATION] `dry_run: true` still opens a write transaction and locks the row

The dry run runs inside `repo().transaction/1` and takes `FOR UPDATE` on the
product before deciding to write nothing. Harmless for a single call; a
catalogue-wide preview holds a row lock per product for the length of its own
transaction. Reading without the lock would be enough for a preview, but the
current shape keeps one code path for both modes, which is the safer trade for a
repair tool.

### 5. [OBSERVATION] The identity tail is appended after the cap, so a slug can exceed 60 characters

`with_identity_tail/2` runs on the already-capped base, so `<60 chars> <> "-22153"`
is up to 66. That is correct — the id has to survive — but the comment "capped
at 60 chars on a word boundary" reads as absolute, and the tests only assert
`<= 60` for the tail-free cases.

### 6. [OBSERVATION] The tail source is arbitrary when the default language has no slug

`default_lang_slug_value/1` prefers `Translations.default_language()`'s key and
otherwise takes `slug_map |> Map.values() |> Enum.find(...)` — map order, not a
defined precedence. Pre-existing, but it now decides the identity tail carried
onto *every* newly generated slug rather than just the empty-slug fallback. In
practice a product always has a default-language slug (the changeset generates
one), so this is a latent edge rather than an active defect.

### 7. [NITPICK] The moduledoc references `regenerate_slug/2`

The `@spec` and the commit title both say `/3`. The `/2` head does exist (default
argument), so nothing is broken — the reference is just inconsistent with how the
function is otherwise named.

### 8. [OBSERVATION] Head-segment-first assumes the product name leads the title

`"IKEA | Wooden Vase"` yields `ikea`. That matches the catalogue this targets
(where the head is the product name and the tail is category/marketing), and the
`""`-head fallback covers the CJK case, but a supplier feed that leads with the
brand would produce brand-only slugs. Not a change to make on speculation —
recorded so the assumption is explicit.

## What Was Done Well

- `cap_word_boundary/2` handles the exact-boundary case (`slug[max_len] == "-"`)
  that a naive "drop back to the last dash" would get wrong by throwing away a
  complete word. It is called out in a comment *and* pinned by a test that
  constructs a title landing exactly on 60.
- The `\\d{4,}` threshold on the identity tail is the right discriminator: it
  keeps `unique_slug/3`'s own `-2`/`-3` suffixes from being promoted into
  permanent ids, and there is a test for exactly that.
- The second commit's `strip_identity_tail/1` fix is the correct shape — it keeps
  `with_identity_tail/2` as the single place that appends, instead of adding a
  second "does it already have one?" check at the fallback.
- `regenerate_slug/3` reuses `merge_translation/3`'s transaction + `FOR UPDATE`
  shape rather than inventing a new one, and its documented contract (`:no_title`,
  unchanged old/new, dry run) is fully covered by tests.
- The write-once rule and its deliberate exception are documented in the
  moduledoc, including the fact that this module owns no redirect bookkeeping.

## Verdict

**Approved with fixes.** The slug shaping is careful work and the edge cases are
genuinely handled rather than hand-waved. One real defect: the new write path
repeats `write_merged/3`'s missing `unique_constraint`, and the shorter slugs
this PR produces make the collision it exposes routine rather than theoretical.
Fixed with a regression test.
