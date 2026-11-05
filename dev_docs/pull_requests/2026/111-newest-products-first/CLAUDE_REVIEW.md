# PR #111 — List the newest products first when hidden categories are excluded

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-29, `a76ae6d`
- **Reviewer:** Claude, 2026-11-05, against `main` at `0337d18`

## What was checked

- **The cause is real.** `distinct: p.uuid` is `DISTINCT ON (uuid)`, which forces
  `uuid` to the front of `ORDER BY` ahead of `desc: inserted_at`. UUIDv7 ascending
  is oldest first, so the newest products came out last, as the PR says.
- **The replacement is equivalent, apart from one improvement.**
  `is_nil(p.category_uuid) or p.category_uuid not in subquery(hidden)`: the subquery
  selects a primary key, so it holds no NULL to defeat `NOT IN`, and the explicit
  `is_nil` keeps uncategorized products. A product pointing at a missing category
  stays visible, as before. The one change is a category whose nullable `status` is
  NULL: `c.status != "hidden"` was NULL and dropped its products, and they now show,
  which agrees with `StatusLabels.category(nil)` ("A category without one is active").
- **Schema prefix.** `Category` declares `PhoenixKit.SchemaPrefix`, so the subquery
  targets the same schema as the outer query.
- **Stable pages.** Both list paths gained `desc: p.uuid` as a tie-break, so
  products inserted in the same microsecond cannot move between pages.

## Findings

None.
