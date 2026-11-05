# PR #92 — Split the Gettext backend by locale and domain

- **Author:** Max Don
- **Merged:** 2026-10-15, `58f7abc` on `main`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`

Reviewed late: Codex and Grok reviewed it, and Claude had not.

## What was checked

- **One option on the backend, nothing else.** `split_module_by: [:locale, :domain]`
  leaves `PhoenixKitEcommerce.Gettext` as the public module, so every
  `use Gettext, backend:` call site is unaffected.
- **Supported by the locked gettext (1.0.2).** `gettext_backend_test.exs`, added
  after Grok's review, pins the dispatch to one `T_<locale>_default` module per
  locale from the parent BEAM, so a removed option cannot hide behind leftover
  split modules.

## Findings

None. Grok's note that `:domain` splits nothing while only `default.po` exists
still holds and is harmless.
