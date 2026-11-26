# Change report: trust workload, escalation deadlines, document-access monitor (chunk C)

**Status: built and tested locally. Not tested on real Supabase or a phone.**

- `0028_trust_workload_and_access_monitor.sql`: `verification_workload()` (counts per queue for sellers and businesses, my open work, who holds what, escalations past the deadline) and `verification_access_monitor(hours)` (document opens and ID views per officer, flags unusual volume; viewing it is audited). Support role plus two-factor only. Settings `verification.escalation_due_hours` (24) and `verification.access_alert_per_day` (30) are starter values for you to set.
- App: `/trust/workload`, linked from User & Trust Management.
- Escalation deadlines are reported, not enforced: nothing reassigns or notifies automatically until the scheduled jobs (chunk G) exist.
