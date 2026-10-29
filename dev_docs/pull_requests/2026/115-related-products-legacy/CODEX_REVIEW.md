# PR #115 — hand-picked related products

Reviewed 2026-10-29 against merge `26ea4bf`, on `6fc923f`.
Author: Tymofii Shapovalov (`timujinne`).
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/115

Compared the recent merges with the existing Codex reviews: #110–114 already
have reviews; #115 is the new unreviewed merge. Applied the Phoenix and Ecto
thinking skills. Traced the Legacy queries, metadata ownership, storefront
cards, category fallback, availability hook, settings authorization/audit,
and the installed core SearchPicker component and JavaScript protocol.

## BUG - MEDIUM: selected products hide remaining search matches

The picker fetched ten matches and then removed the current product and
already-picked products. If those occupy the ten results, the picker reports
no matches even with more matching products in the database. This can stop
the merchant filling the supported twelve slots.

Fixed by excluding those UUIDs in the Legacy query before its limit. A
LiveView regression stages ten matching products, searches again and fills
all twelve slots. It failed against the merged implementation.

## BUG - MEDIUM: the picker cannot load matches beyond the first ten

Core starts with `limit: 8`, increases that limit for Load more, and renders
that action only when the server answers `has_more: true`. The new handler
ignored the requested limit and always answered false, making older matches
unreachable for a shared title/search term.

Fixed by honoring the hook's cumulative limit, fetching one extra row to
detect more matches, and returning the requested prefix. Searches are bounded
to 100 suggestions; malformed/nonpositive limits use eight. A regression
drives 8-, 16- and 24-row requests over nineteen matches and verifies stable
prefixes and exhaustion. Another covers malformed client limits. The
pagination regression failed against the merged implementation.

## IMPROVEMENT - MEDIUM: availability checks continue after the block fills

The filter eagerly consulted the hook for every candidate before taking the
display limit: up to twelve calls for a chosen list and thirty-six for the
category fallback. A host hook may call a stock service, so unused candidates
add avoidable latency and failures to every page load.

Changed filtering to a stream, stopping once enough available products are
found. A regression verifies that an unavailable first candidate is skipped,
the next available product fills the block, and later candidates never reach
the hook. It failed before the change.

## IMPROVEMENT - MEDIUM: gate every related-list editing event

Search and pick rechecked `shop.manage_catalog`, but remove and move changed
the staged list after the socket lost that capability. Saving was already
gated, so this was not an unauthorized database write.

Added the same per-event authorization to remove and move, using private
`gated_event/3` clauses. A regression revokes permission after mount and
verifies both the original chips and their order survive attempted edits.
It failed against the ungated handlers.

## Validation and limits

Final results are recorded in [FOLLOW_UP.md](FOLLOW_UP.md).

No additional finding in metadata merging, UUID normalization, draft/hidden
filtering, localized card links, or settings audit/authorization. The existing
category fallback intentionally samples at most three times the display limit;
it can remain empty if all sampled products are unavailable. Related products
remain Legacy-only. These changes use core's existing hook and add no JavaScript.
Compared all six translation catalogs across the merge: each retained 1,436
existing messages with no changed translations.

No dependency change, version bump, CHANGELOG entry or release.
