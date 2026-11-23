# PR #122 follow-up

- The findings in `CODEX_REVIEW.md` and `VIBE_REVIEW.md` were fixed on main
  before this pass (`a7d45c9`, `f93c374`, `2463131`): locked-row rebase
  multiplier, selection resolved by format, first-visit cookie without a
  forced `secure` flag, `@impl` only when the installed core lists the
  callback, cookie verification through `Plug.Crypto.verify/4`.
- **BUG - MEDIUM** — `CartMove` capped every move, including a storefront
  handoff, at the cart API quantity (99). The default ceiling is now the cart
  line's own (`CartItem.max_quantity/0`). Only the claim merge passes the API
  cap. Regression tests cover a quantity above 99 on `move_cart_lines/3` and
  on `handoff_apply/2`.
