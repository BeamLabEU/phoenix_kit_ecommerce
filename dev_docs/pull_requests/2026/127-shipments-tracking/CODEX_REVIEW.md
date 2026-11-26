# Shipment tracking and automatic registration

Reviewed PR #127 at `681bfb1`.

**BUG - HIGH** A second paid-event handler could see no shipment, finish destination validation after the first shipment became terminal, and insert a second row. The live-row index permits terminal history. Registration now rechecks for any prior row under the order write lock when handling payment. A regression test finishes another shipment during validation and checks that the carrier receives no registration call.

**BUG - MEDIUM** A malformed HTTP status could include private carrier text in the tracking log or raise while reporting the failure. Tracking now formats only integer statuses and keeps the error tag for malformed replies. The regression checks the log and stored event.
