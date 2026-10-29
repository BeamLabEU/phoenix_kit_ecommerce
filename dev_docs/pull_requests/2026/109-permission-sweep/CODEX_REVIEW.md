# PR #109 — admin sub-permission gates

Reviewed 2026-10-29, merged commit `73b7aeb`, rechecked on `851f31a`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/109

No new functional finding. Checked each added mount guard against its tab's
permission and the tab-less routes, and checked the AI translation event list
against the installed AI Embed hook. The shop hook attaches first and checks
the current scope before translation events can enqueue work. The public
context API remains scope-less as required by this repository.

The permission, route, and product context tests passed together: 82 tests,
zero failures. Final full-suite and gate results are recorded in the
[PR #112 follow-up](../112-checkout-phone-requirement/FOLLOW_UP.md).
