# Application diagnostics

The local application journal extends the existing `Diag`, auth diagnostics and
Sync Health facilities. It adds a common, content-free timeline across features;
it is not an analytics feed or a replacement for server-side logs.

## Coverage

| Boundary | Evidence retained |
| --- | --- |
| Foreground startup | Start, completion and failure of bootstrap steps; related child operations share a trace. |
| Session and authentication | Session presentation transitions, provider login journeys, refresh diagnostic activity. No identity or credential values. |
| All Drift connections, including secondary connections | Reads, writes, commits and rollbacks counted. Failures and queries taking at least 500ms enter the timeline. Known writes are classified as accounts, transactions, budgets, goals, bills, cards, settings, catalog, coupons or engagement. SQL and values never enter the journal. |
| Gated HTTP | Admission refused, dispatched, response headers/status, body completion/cancellation/failure. Only a fixed endpoint category survives. URLs, query parameters, headers and request/response bodies are excluded. HTTP/body completion is not proof of business acceptance. |
| Sync Health | Distinct outcomes for ledger, planning, accounts, children, inbox, sender mappings and engagement; permission and capability stops remain blocked states. |
| Consent and settings | Locally committed choice and consent revision; settings enqueue preparation; sync skips and acknowledged delivery; separate device-consent receipt. Pending enqueue evidence is not a transaction commit. Device confirmation is not account-settings confirmation. |
| Capture and parsing | Capture-import invocation and parsing result, exception, no-match or timeout. Message contents, sender and capture IDs are excluded. |
| Backup and restore | Backup, restore preparation and restore execution journeys. Passphrases, keys, files and records are excluded. |
| Reports | Export journey, including child database/network operations. Report contents are excluded. |
| Notifications | Scheduling journey, disabled preferences and immediate-display success/failure. Notification text and payloads are excluded. |
| UI across features | Navigation events, provider errors, Flutter errors and unhandled platform errors. Only allowlisted feature areas survive classification; route parameters, provider family values, exception messages and stack text are excluded. Existing handlers still receive the original errors. |
| App lifecycle | Foreground, inactive, background and detached events, with best-effort journal flush. |

`completed` means the instrumented Future returned. It does **not** mean every
business action succeeded: a method can return a refusal or a no-work result.
Explicit `confirmed`, `blocked`, HTTP `response` and domain events provide that
distinction. The observer never changes retries, permissions, consent or results.

## Storage and access

- A foreground launch reads/writes `app_diagnostics_v1.json` in application support.
- At most 500 events, retained for at most two days when the journal is loaded or
  appended. The restore reader refuses files above 192 KiB. Normal writes are
  debounced and serialized, then atomically replace the previous file.
- High-volume database successes are counters, not one log entry per statement.
  Counters reset per engine/process; persisted timeline events survive restarts.
- The foreground engine owns its journal. The single headless capture-drain
  host writes a separate `app_background_diagnostics_v1.json`, with a bounded
  best-effort flush before returning to native. The support export reads that
  file without changing it, so the engines never overwrite each other's file.
  The same size and retention limits apply independently to each file. Pure
  native work that runs without Dart retains its existing native diagnostics.
- Nothing in this module uploads logs, initializes an SDK, or changes Cloud-off
  behavior. Existing Sentry remains behind its existing consent and egress gates.
- The regular Settings support group has a localized **Copy diagnostic log**
  action in release and development builds. This copies the bounded journal and
  counts only. Developer-only Sync Diagnostics additionally shows recent app
  events and includes them in its existing **Copy diagnostics (redacted)** export.
- Persistence failures, malformed files and unknown serialized fields are
  ignored safely. No raw exception message is used as a fallback.

## Verification

The local device reproduction on build 138 distinguished `deviceConsent:
confirmed` from a missing settings delivery: OFF queued consent version 95, but
ON logged `settingsQueue: blocked/unavailable` at version 96. Both foreground
registration-service constructors now receive the durable planning outbox.
The native reserved-consent commit and the ordinary enable use that same atomic
settings/outbox transaction. No backend flag is manually changed to repair this.

Active Cloud/AI status additionally checks the account's two flags and exact
consent version through a same-owner metadata-only GET. Device acknowledgement
remains the sync prerequisite, avoiding an account-confirmation/sync deadlock.
Setup may advance with a saved pending choice before authenticated sync exists;
the live status remains pending until account confirmation. A settings sync
refreshes these facts. Read failures, stale scopes and mismatches never confirm
the account.

The build-139 phone retest also exposed the legacy settings transport treating
ON as a full-row timestamp conflict after the preceding OFF RPC had advanced the
account row. Explicit consent now uses the existing field-scoped settings
delivery in both transport modes. A repeated explicit choice requeues its
consent fields at the same stored version. The consent flow flushes settings
directly before checking the account, independently of the shell's poll timer.

The offline phone test confirmed local OFF 103 while the account remained at
ON 102, then converged both server rows to OFF 103 through the persisted revoke
retry. The foreground returned at 19:03:13 UTC, but the existing retry schedule
did not send until 19:05:02 UTC. Foreground resume and explicit Retry now attempt
only that pending OFF immediately; automatic timer retries retain their bounded
backoff and all existing owner, gate and newer-grant checks. The pending-OFF copy
distinguishes stopped local processing from unconfirmed server state.

`app_diagnostics_test.dart` exercises correlation, concurrent operations, error
identity, privacy, retention, bounded storage, restart, corrupt files and storage
failures. `app_diagnostics_integration_test.dart` drives the actual AppDatabase
interceptor, SQL rollback, gated HTTP denial/response, providers, navigation and
support export. The ordinary Flutter suite checks that instrumentation preserves
the existing lifecycle, consent, sync, parser, notification, backup and UI behavior.
