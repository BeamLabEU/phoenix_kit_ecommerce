# PR #122 follow-up review

Reviewed the changes since Hex 0.12.0 through `f93c374`, including the follow-ups to the merge.

## BUG - HIGH — Repeating a base conversion could change prices twice

A stale caller supplied the multiplier before locking the cart. If a second request had already converted it, the retry multiplied the new base price again. The rebase now checks the locked row and derives the multiplier from that row. When a domain currency change includes a rebase, subscribers receive only the finished cart. The regression test exercises a domain change, its broadcast and a retry using the original struct.

## BUG - HIGH — A transferred line could select a different catalogue variant

A label stored on an older cart line could be interpreted as the key of a different variant, changing the item and its price. A target line with the same text could also consume that variant’s quantity allowance. The move now resolves the stored selection by its format, preserves explicit API options and checks the cap against the line that add-to-cart would update. Two catalogue integration tests cover the source and target collisions.

## BUG - MEDIUM — First-visit cart cookies could be lost on HTTP

The handoff forced the secure flag on every response. It now passes the signing and lifetime options and lets core apply the target scheme. The round-trip test reads the signed cookie back through the shop plug.

## BUG - MEDIUM — The locked Hex core rejected the callback annotations

The shop supports core versions on both sides of the handoff addition. Each hook now declares its implementation attribute when the installed behaviour lists the callback. Both versions retain the same shop API.
