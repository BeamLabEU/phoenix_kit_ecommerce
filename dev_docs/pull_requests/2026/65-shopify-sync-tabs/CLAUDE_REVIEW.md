# PR #65 — Shopify sync page: Changes / New in Shopify / Media & collections / Settings tabs

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-09-22, `d2858e6` on `main`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`

No review existed for this PR. `web/shopify_sync.ex` has had seven later
commits, so this reads the tab code as it stands today.

## What was checked

- **`?tab=` is a whitelist.** `valid_tab/1` falls through to `"changes"` for a
  missing value, an unknown value and a non-binary one (`?tab[]=x`), so a crafted
  URL cannot crash the page or render nothing.
- **Tab links use `patch:`.** A switch runs `handle_params/3` only, so `@changes`,
  `@pending` and `@media_sync_progress` survive it, and the PubSub progress handler
  updates its assign whichever tab is showing. Paths go through `Routes.path/1`.
- **Load-more counters.** `new_products_loaded` resets on a new check. The media
  error and warning lists keep separate counters per kind. A counter left high
  after a later, shorter run only means "show everything", which is harmless.
- **Authorization.** The load-more events only widen what the page already shows;
  every write path still goes through `Authz.authorize/3`.

## Findings

### NITPICK — the `load_more_rows:` comment is out of date (left open)

`web/shopify_sync.ex:417` says core's `<.load_more>` forwards nothing and to
collapse the per-field event names "once this package's floor carries it". The
floor does: core 2.65.0 has `attr :rest, :global` and `{@rest}` in
`pagination.ex`, and the media lists in this file already use `phx-value-kind`.
Left as is: it is a working event name, and nothing in the test suite refers to it
by name, so collapsing it is a small refactor with no behaviour to gain.

### NITPICK — `render/1` rebuilds the change sections on every render (left open)

`build_sections/1`, `build_everything/1` and `build_change_stats/1` run in
`render/1`, so each `:media_sync_progress` broadcast rebuilds them even while the
Media tab is showing. This predates the PR (the same calls sit in
`d2858e6^`) and `@diffs` already memoizes the expensive text diffs. Worth moving
to assigns only if a large sync shows up as slow.
