# PR #11 follow-up — Admin i18n wave: gettext-wrap all admin LiveViews, module backend, ru/et catalogs

Triaged 2026-08-04 during the ecommerce quality sweep. All four findings in
`CLAUDE_REVIEW.md` were fixed inside the PR itself; re-verified against
current code.

## Fixed (pre-existing)

- ~~**#1 [BUG - MEDIUM] `product_form.ex` — Translations tab and 7 other help strings never wrapped**~~ — fixed in-PR.
- ~~**#2 [BUG - MEDIUM] Additional unwrapped strings in `products.ex`, `imports.ex`, `import_show.ex`, `category_form.ex`**~~ — fixed in-PR.
- ~~**#3 [NITPICK] Fuzzy-merge poison reintroduced by `mix gettext.merge`**~~ — cleaned up as part of fixes 1 and 2. Worth remembering as a recurring trap: `mix gettext.merge` writes fuzzy guesses that render at runtime, so a merge after an extraction gap silently ships wrong translations. Merge with `--no-fuzzy`.
- ~~**#4 [BUG - MEDIUM] Two list-header counts used `gettext` instead of `ngettext`**~~ — fixed in-PR, with translations for all three locales.

## Notes carried forward

The review's own conclusion is the useful artefact here: the same two bug
classes — **incomplete wrapping coverage** and **missing `ngettext` on count
strings** — recurred in files the first pass did not reach. That is a
statement about the method, not the author: wrapping sweeps done by reading
templates top-to-bottom miss strings in help text, tab labels, and
conditional branches.

The sweep's own translation triage (running now) uses a different approach
for exactly that reason: grep for user-facing string literals and check each
against its surrounding call, rather than re-reading templates.

## Files touched

None in this follow-up — all four findings were resolved inside the PR.

## Verification

`mix precommit` exit 0. Suite: 245 tests, 0 failures via `PHOENIX_KIT_PATH=../phoenix_kit mix test`.

## Open

None.
