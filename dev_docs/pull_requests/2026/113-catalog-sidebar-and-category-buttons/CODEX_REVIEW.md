# PR #113 — catalog sidebar and category buttons

Reviewed 2026-10-29 at merged commit `851f31a`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/113

Resolved the conflicts with PR #112 by regenerating the Gettext template and
catalogs without fuzzy merging, then restoring translations from both branches.
Verified every translated message retained by the merged template preserves
its translation. Pushed the resolution to the PR branch, merged the PR, and
pulled `main` into this checkout.

No additional functional finding. Checked both storefront pages with the
sidebar on/off, cards/buttons, filter navigation, single/multiple languages,
and the settings permission and audit wrappers. Defaults retain the existing
layout. The shared category links use the established route builders.

Before merge, the catalog/settings and checkout-phone tests passed: 42 tests,
zero failures, three compatibility cases skipped because the locked billing
does not declare `require_phone`. `mix precommit` passed, including Dialyzer.
Final full-suite results are in the
[PR #112 follow-up](../112-checkout-phone-requirement/FOLLOW_UP.md).
