# Shipment registration

Reviewed PR #125 at `ac4b72d`.

**BUG - MEDIUM** PostgreSQL rejects a NUL in either text or JSONB. A carrier rejection containing one could leave an attempted shipment in `creating` until the sweep classified it as unknown. The masking function now replaces NUL before persisting carrier messages. A registration test checks both the failed state and its event.

Reviewed the V7 table and live-order index, paid-order checks, submission claim and recovery of uncertain outcomes.
