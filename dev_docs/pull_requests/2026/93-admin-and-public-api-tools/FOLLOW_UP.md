# Follow-up — PR #93

| Finding | Severity | Resolution |
|---|---|---|
| Category delete never reindexed its products | BUG - MEDIUM | `Subscriber` rebuilds on `:category_deleted`; test added. |
| Base-currency change left old-base prices in the index | BUG - MEDIUM | `Subscriber` subscribes to `{:currencies_changed, _}` and rebuilds; test added. |
| Image downloader kept Req's default retry (uncapped `Retry-After`) | BUG - MEDIUM | `retry: false`. |
| `WarehouseSourceKind` queried the catalogue table without the schema prefix | BUG - MEDIUM | Prefix from `:phoenix_kit, :prefix`. |
| `list_item` output schema required fields `fields` can drop | BUG - MEDIUM | Only `id` required. |
| Merged assistant carts never pruned | IMPROVEMENT - MEDIUM | Prune covers `merged`; test added. |
| `set_prices` accepted a price with no currency anywhere | IMPROVEMENT - MEDIUM | Row refused; tests added. |
| `set_availability` wrote without the item lock / re-plan | IMPROVEMENT - MEDIUM | `write_if_unchanged/4` with its planner. |
| Cart settings form: no audit row / stale form on a partial write | IMPROVEMENT - LOW | Each stored value audited; form reassigned. |
| V4 / V5 SQL not digest-pinned | IMPROVEMENT - MEDIUM | Digests added (V4, V5 claims table). |
| Doc drift (danger functions, cache clearers, claim page revision) | NITPICK | Fixed in AGENTS.md and moduledocs. |
| Claim merge 99-per-line cap | NITPICK | Left: two tests pin it as intended. |
| Everything else in "Not changed, on record" | see review | Left for the maintainer; reasons in `CLAUDE_REVIEW.md`. |
