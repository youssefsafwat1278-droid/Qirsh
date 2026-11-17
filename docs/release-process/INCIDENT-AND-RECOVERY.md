# Incident and recovery

What can and cannot be undone after a Qirsh release, and how to respond. This file states capabilities in general terms; each release's `RELEASE-PLAN.md` says which of them exist and were verified for that release. Do not rely on a capability that a release plan marks unverified.

## What "roll back" means per component

| Component | Can it be reverted? | Reality |
|---|---|---|
| Installed mobile app | No. | A shipped build stays on devices until the user updates. The stores do not downgrade users. The fix is a new build with a higher build number (forward fix), which on iOS passes through TestFlight processing and, for App Store users, review. |
| App Store phased release / Play staged rollout | Can be paused or halted. | Pausing stops *new* users receiving the build. Users who already have it keep it. |
| TestFlight build | Can be expired. | Expiring stops new installs and eventually stops the build launching for testers; it does not restore the previous build's data. |
| Device database (Drift) | No. | Migrations are forward-only. A newer schema cannot be opened by an older build. A bad migration is repaired by another migration in a new build. |
| Production database schema | Sometimes. | Only where a specific rollback file exists in `supabase/rollback/` **and** it has been rehearsed **and** no data written since depends on the new shape. Otherwise use a forward-fix migration. Platform backups / point-in-time recovery restore the *whole* database to a moment and lose everything written after it; treat that as a last resort and confirm with the provider plan what is actually available. |
| Edge Functions | Yes, by redeploying the previous version from its commit. | Safe only if the database shape the old version expects still exists. |
| Admin panel | Yes, by redeploying the previous version. | Same condition. |
| Remote feature flags | Yes, immediately, for features that have a flag. | Only effective for clients that fetch flags, after their cache expires, and only for code paths that check the flag. A flag that was never tested in the off position is not a recovery mechanism. |
| Data already sent to a third party | No. | Containment and disclosure, not reversal. |

## Severity during an incident

| Level | Examples | First response time (target) |
|---|---|---|
| SEV-1 | Data loss or corruption; cross-account exposure; transmission without consent; wrong amounts at scale; app unusable for most users. | Start containment immediately; owner informed at once. |
| SEV-2 | A core journey broken for some users; capture failing on one platform or OS version; push or AI path down. | Same day. |
| SEV-3 | Degraded or cosmetic. | Next working day. |

These are targets for a small team, not a service-level commitment.

## Response steps

1. **Stabilize.** Stop widening the rollout (pause phased release / staged rollout; hold further deploys).
2. **Contain** with the least destructive lever that exists and was verified for the release:
   - turn off the affected feature by flag;
   - redeploy the previous function version;
   - disable the affected scheduled job;
   - for a privacy incident, stop the egress path first, then investigate.
3. **Preserve evidence.** Record times, versions, affected accounts by identifier only. Do not copy user financial data into tickets or chats.
4. **Assess scope.** Which builds, which platform, how many users, since when, whether data was lost, altered, or exposed.
5. **Decide the fix.** Forward-fix build, forward-fix migration, or configuration change. State what cannot be recovered.
6. **Communicate.** Users affected by data loss or exposure are told what happened and what to do. Legal and store notification duties depend on jurisdiction and the incident; the owner decides with advice. This document does not determine those duties.
7. **Verify and reopen.** Re-run the affected checklist items on the fix; resume rollout from the smallest audience.
8. **Review.** Within a week: what happened, why it was not caught, which checklist item or test changes. Add the item; do not just add a note.

## Recovery of user data

- Local data lives on the device. If the app cannot open it, the path is a fix build that can, not a reinstall (a reinstall deletes the app container; the keychain may survive).
- Users with a backup or Cloud Sync can restore to the extent those features were verified for the release. Say so only if they were.
- Server data relies on the database provider's backup capability. Record in the release plan what tier is in place and when a restore was last rehearsed. "Never" is an acceptable entry; an unstated assumption is not.

## Ownership

Each release plan names: the incident owner, a backup contact, where users report problems, and the observation window during which someone is watching the signals. For a one-person team, name the hours that are actually covered.

## Mobile-specific cautions

- Never ship a build that lowers the device schema version or the build number.
- A fix build must be tested as an *upgrade* from the broken build, on a device holding data written by the broken build.
- Consent state changes must be honoured by queued and retrying work in the fix build as well; re-verify revocation after any change to capture or sync.
