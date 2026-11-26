# Shipment administration

Reviewed PR #126 at `470d92d`.

**BUG - MEDIUM** The label controller silently discarded empty entries and non-string list elements. The UUID cast also accepted arbitrary 16-byte input as a binary UUID. The controller now passes all entries to validation, which requires textual UUIDs and rejects the entire request before printing. Controller tests cover mixed valid and invalid IDs.

Checked permission gates on the page and download route, provider grouping, label audit data and the destination picker.
