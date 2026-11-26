# Change report: product comparison and duplicate photos (chunk D)

**Status: built and tested locally. Not tested on real Supabase or a phone.**

- `0029_comparison_and_duplicate_photos.sql`: `compare_listings` (2 to 4 visible listings), photo fingerprint read by the database from the stored file's ETag, flags for the same file on another seller's listing, a moderator/support queue and resolve step (audited, not on your own listings), counts-only view for sellers.
- App: "Compare with other items" on a listing, a `/compare` screen (lowest price marked, unavailable items reported, different categories warned), and `/trust/photo-flags` for staff.
- **Limits:** only byte-identical files match; a cropped or re-compressed copy is not caught (needs an image-hashing worker, not built). Nothing is blocked or removed automatically. Photos uploaded before this migration have no fingerprint. The ETag format on a real Supabase project has not been checked, so confirm on staging that `content_hash` fills in.
- The seller-facing count (`listing_duplicate_photos`) exists in the database but no app screen shows it yet.
