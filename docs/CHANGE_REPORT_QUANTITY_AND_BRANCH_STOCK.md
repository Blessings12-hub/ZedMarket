# Change report: quantity reservations, branch stock and partial fulfilment (chunk E)

**Status: built and tested locally (SQL suite, race tests, app logic, typecheck). Not tested on real Supabase or a phone.**

## What changed
- `0031_quantity_reservations_and_branch_stock.sql` (numbered 0031 because main already has 0030_province_listings). Orders have a quantity; a listing with counted stock can be reserved by several orders at once, never beyond the stock; one-off items are unchanged. Stock is still taken off at completion. `create_order`, `confirm_order` and `mark_handed_over` gained optional trailing parameters (quantity, branch, quantity handed over), so older app versions keep working. The order total is now price x quantity handed over (or ordered) + delivery.
- Stock per branch: `set_branch_stock`, `branch_stock`; first use moves a listing's existing stock into its own branch; the total can only change through the branches afterwards; the seller picks the branch when confirming; completion takes units from that branch.
- Partial fulfilment: the seller states how many were handed over; the total and stock follow it. The receipt shows both numbers.
- App: quantity box on checkout (counted stock only), quantity lines on the order screen, branch choice when confirming, "how many handed over" for the seller, a "Stock per branch" screen from the Stock page.

## Known limits
- Analytics "items" still adds the unit price once per order, not times the quantity.
- Payments stay disabled; when built they must charge the total after hand-over.
- Cart checkout still orders one unit per item.
- The count shown to buyers is capped at 20.
- Not tested on real Supabase or a phone.

## Housekeeping
Five empty stray files were uploaded to main by accident (`business-onboarding/v`, `comparison/v`, `trust-workload/b`, `trust/business-application/b`, `birthdays/c`). The bundle's `DELETE_ON_MAIN.txt` lists them.
