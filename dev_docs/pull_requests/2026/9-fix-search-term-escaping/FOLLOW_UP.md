# PR #9 follow-up — Escape LIKE metacharacters in search terms; filters-aware category empty state

## No findings

`CLAUDE_REVIEW.md` recorded **no issues** and approved with no changes
requested. Re-verified against current code on 2026-08-04 during the
ecommerce quality sweep:

- `search_like_pattern/1` still escapes `\` before `%` and `_`, which is the
  order that matters — escaping the backslash last would re-escape the
  backslashes just inserted for `%`/`_`.
- Re-grepped for unescaped `"%#{...}%"` interpolation into `ilike`/`like`
  across `lib/`: none. The one search path added since this PR (the
  >100-row SQL branch) routes through the same helper.

Reviewer: Claude. Nothing outstanding.

## Open

None.
