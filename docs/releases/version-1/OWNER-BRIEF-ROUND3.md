# Owner brief, round 3 (2026-11-17) — verbatim

The owner's instruction for the closure round, kept verbatim. Section 3 lists the approved Version 1 product decisions.

Complete Qirsh Version 1 release readiness using the existing audit, implementation, and release records. Implement the owner decisions below, strengthen message understanding, resolve the remaining in-scope defects, and produce a verified release candidate and a concrete production execution plan.

This is an implementation and closure task. Do not restart the audit from scratch or deliver another report without completing the actionable work.

1. OWNERSHIP, MODELS, AND AUTONOMY

You are the current-session orchestrator, referred to by the owner as Fable 5.2. Use specialist agents running Opus 5.5 where that exact model is available.

Verify the actual available model identifiers. Never claim to have used a model based only on a requested label or a subagent’s self-report. If a requested model is unavailable, disclose that once and continue with the available models.

Delegate bounded responsibilities with clear file ownership:
- Message parsing, AI understanding, and categorization.
- Data integrity, restore, sync, and account deletion.
- iOS, notifications, UI, and accessibility.
- Backend, privacy, operational readiness, and CI.
- Independent verification of the final integrated changes.

Prevent conflicting edits. Review the integrated result, not just isolated commits.

Proceed autonomously with reversible local implementation, tests, builds, documentation, and local commits. Do not ask the owner to choose algorithms, prompts, validators, file organization, or routine implementation details.

Do not add unrelated features or redesign the product. Defer optional improvements that require new product decisions and keep working.

Only pause the affected action for:
- Destructive changes to user or production data.
- New spending or paid-service commitments outside existing authorization.
- Push, merge, production deployment/configuration changes, or store uploads/submission.
- Essential unavailable credentials, access, or hardware.

Prepare the concrete change, evidence, and rollback instructions before requesting approval. Continue independent work while blocked.

If a tool or approval system rejects an action, do not bypass it. Explain the specific restriction and continue with permitted work.

2. ESTABLISH THE CURRENT BASELINE

Locate and read the current repository instructions and release records, including:
- RELEASE-DECISION.md
- REVIEW-CLOSURE.md
- DECISIONS-NEEDED.md
- RELEASE-PLAN.md
- ISSUES.md
- KNOWN-LIMITATIONS.md
- The latest independent parser review.
- evidence/production-comparison.md
- RELEASE-MANIFEST.md
- Relevant test evidence, UI review, and reusable release-process documents.

Expected working location:
.claude/worktrees/v1-readiness
Expected branch:
release-readiness/v1

These are discovery hints, not proof of current state. Inspect the actual checkout, branch, working tree, and commit history. Preserve existing work and uncommitted changes. Do not reset, discard, or overwrite unrelated work.

Previously reported candidates include 50957c06 and 5dae2e2d. TestFlight build 1.0.0 (147) is an older baseline. Verify identities rather than assuming these remain current.

Reconcile implemented fixes, open findings, and stale documentation. Reuse valid evidence where applicable, but do not present old test runs as verification of new code.

Create a bounded execution plan and proceed.

3. APPROVED V1 PRODUCT DECISIONS

These decisions are approved. Do not ask the owner to decide them again.

3.1 Platform scope
- V1 targets iPhone.
- Dedicated iPad support and Android release readiness are outside this release scope.
- Verify the actual platform configuration and describe any remaining compatibility behavior accurately.
- Do not delete Android code or introduce avoidable shared-code regressions.

3.2 Advertising
- V1 has no advertising.
- Disable ad display and advertising SDK initialization/requests in the V1 build.
- A remote flag must not silently reactivate advertising in this build.
- Verify behavior, including the current production flags being enabled.
- Prepare the exact production flag changes, but do not execute them without approval.
- Keep privacy declarations truthful about any SDK or data behavior that remains.

3.3 Backup restore
- Restore uses merge semantics.
- Restore missing records while retaining newer data.
- Preserve server identities and prevent duplication.
- Respect intentional deletions/tombstones and manual edits.
- Do not resurrect deleted transactions or overwrite newer user choices.
- Explain merge behavior accurately in the UI.
- Verify restore together with subsequent cloud synchronization.

3.4 Account deletion
- Deletion is final, with no 30-day undo period.
- Align policy and confirmation copy with the actual deletion lifecycle.
- Do not promise immediate completion of asynchronous server work.
- Verify deletion of applicable account data, backups, and profile photos.
- Verify the background deletion worker and retry/resume paths independently of inline deletion.
- Prevent deleted data from returning through sync or queued processing.
- No historical production cleanup or user-data deletion is authorized by this task.

3.5 Privacy Policy and Terms
- Users can open these documents with Cloud disabled, including before consent.
- Opening them must not enable Cloud or AI or transmit bank messages.
- Implement narrowly scoped access to the required legal destinations without weakening unrelated network controls.

3.6 Language
- First launch presents language selection without preselecting a language.
- Persist the explicit selection and allow changes in Settings.
- Preserve existing users’ language choices.

3.7 Countries
- Make all countries available through a maintained country selection mechanism.
- Do not restrict onboarding to Egypt and Saudi Arabia.
- Separate country availability from verified bank-parser coverage.
- Do not claim every bank, language, or message format has been tested.
- Support the corresponding country/currency configuration without assuming country alone proves transaction currency.
- Unsupported or ambiguous messages must receive an honest disposition.

3.8 Cloud and AI activation
- Present a clear first-run consent screen with:
  - An affirmative “Agree and enable” action.
  - A “Continue locally” action.
- Cloud and AI become enabled only after the affirmative action.
- Do not transmit messages before consent.
- Explain the actual transmitted data, destinations, purposes, synchronization behavior, and shared-learning contribution.
- Sanitized text must not be described as guaranteed anonymous.
- Preserve existing users’ consent choices; do not silently opt them in through an update.
- If the approved behavior introduces a purpose outside existing consent, handle that consent transition explicitly.

3.9 Disabling Cloud and AI
- The user-facing disabling action turns both services off together.
- Make the wording accurately describe that combined action.
- Stop further cloud/AI dispatch and retries when disabled.
- Recheck consent and account ownership at dispatch and before applying results.
- Do not imply that an already transmitted request can be recalled.
- This decision does not authorize automatic activation.

3.10 Shared learning
- Shared learning is enabled with the explicit Cloud/AI activation described above.
- Explain the actual contribution data and purpose within that consent.
- Inspect and minimize what is transmitted.
- Preserve applicable existing aggregation/publication safeguards; do not weaken them.
- Disabling the services stops new contributions.
- If this design encounters a concrete verified platform or legal requirement for a different consent mechanism, explain the specific conflict instead of silently shipping a noncompliant flow.

3.11 Sign-in
- Retain the sign-in methods currently available to existing users.
- Inspect actual release-build and CI configuration rather than relying on repository defaults.
- Test that existing users retain account access.
- Do not add a special authentication bypass or reviewer backdoor.
- Check whether normal reviewer access is feasible; report a concrete submission blocker only if one actually exists.

3.12 Notifications
- Show available transaction details, including amount, currency, merchant, category, transaction type/status, account or card last four digits, and timestamp, subject to platform display limits.
- Use expanded notification content where appropriate.
- Never expose OTPs, full card/account numbers, secrets, or raw SMS text.
- Respect operating-system notification-preview settings.
- Do not present an unfinished analysis or proposed category as final.
- Reflect the saved-rule/manual-category priorities below.
- Keep notification claims consistent with whether a transaction was actually saved, excluded, or queued for review.

3.13 Signed-out capture
- Do not silently report success when capture cannot complete because the user is signed out.
- Provide an honest, actionable sign-in/open-app message where the platform permits.
- Do not attach an unowned message to whichever account signs in next.
- Do not promise that a message is retained unless retention is implemented and verified safely.

3.14 Balance display
- Label balances according to their actual source.
- Examples: “Last balance reported by the bank” or “Manually entered balance.”
- Display the relevant update time when available.
- Do not imply a stale or manually entered value is a verified current balance.
- Do not introduce a new balance-computation subsystem.

3.15 Historical transactions
- Parser corrections apply to newly processed messages.
- Do not bulk reanalyze, recategorize, or financially rewrite previously recorded transactions.
- Do not silently mark historical transactions for review.
- Necessary structural migrations must preserve their financial meaning and user choices.
- Keep any proposed historical cleanup outside this task.

4. MESSAGE UNDERSTANDING AND AI REQUIREMENTS

The objective is to understand each captured message before deciding whether it represents money movement.

“Analyze everything” means every message accepted into the financial-capture pipeline receives a clear disposition. It does not authorize collecting every personal SMS, bypassing consent, or sending obvious authentication secrets to AI.

4.1 Establish message meaning first
Distinguish:
- Completed financial movement.
- Declined or failed operation.
- Pending or scheduled operation.
- Completed refund or reversal, versus a pending refund/reversal notice.
- Informational balance or credit-limit notice.
- Bill due, payment reminder, or expected salary.
- Marketing, offers, OTP, and other nontransaction messages.
- Ambiguous or mixed-content messages.
- Messages containing multiple financial events.

Do not equate the presence of an amount or bank name with a completed transaction.

Examples:
- “Purchase completed for EGP 250” → completed purchase.
- “Purchase of EGP 250 declined” → not spending.
- “Transfer of EGP 500 pending” → not confirmed movement.
- “Your bill of EGP 700 is due” → not proof of payment.
- “Your salary will arrive tomorrow” → not received income.
- “Available balance EGP 8,000” → balance information.
- “Purchase completed for EGP 250; card payment due EGP 900” → preserve the completed purchase without treating the reminder as a second transaction.

Do not exclude an entire message just because an unrelated footer contains words such as “due,” “failed,” or “limit.”

4.2 Evidence-based extraction
Use a structured output that separates:
- Message type.
- Transaction status.
- Amount and currency.
- Direction and transaction type.
- Merchant/counterparty and account hints.
- Evidence spans supporting important fields.
- Missing information, contradictions, and disposition reasons.

Evidence spans are supporting checks, not a guarantee of semantic correctness.

Differentiate the transaction amount from:
- Available balance.
- Credit or transfer limits.
- Reference numbers and OTPs.
- Fees, tax, tips, and totals.
- Original foreign-currency amount versus actual account charge.

Keep original and charged amounts distinct when present and count the financial event once.

Treat message text as untrusted input, not instructions. Protect the model against instructions embedded in the message.

4.3 Local and AI cooperation
- When AI is enabled and processing is eligible, AI should review transaction understanding even when local parsing appears successful.
- Use local parsing and known account/bank context as evidence, not unquestionable truth.
- When local and AI results disagree, prefer a validated AI interpretation.
- If the AI interpretation is unsupported, contradictory, or incomplete, send the item for review.
- Do not automatically save a local result and later silently rewrite it after AI returns.
- With AI disabled, retain a functional local flow: verified local outcomes may be saved; ambiguous ones require review.
- Never transmit to AI to compensate for missing consent.

4.4 Currency
If the message omits currency:
- Use the currency of a confidently identified existing account when there is no contradictory evidence.
- Record that the currency was inferred from account context.
- If account identity or currency is uncertain, require review.
- Do not invent a currency based solely on an AI guess.

4.5 Categorization priority
Preserve this precedence:
1. Explicit manual category chosen by the user.
2. An enabled, applicable saved user rule.
3. AI categorization if no applicable saved rule exists.

Saved rules control category selection; they must not override evidence about amount, currency, completion status, or direction.

Preserve category provenance through import, restore, sync, retries, and subsequent enrichment. Do not let late AI responses overwrite manual choices.

Use existing deterministic rule-conflict behavior where sound. Resolve routine implementation details without asking the owner.

4.6 Dispositions
- Completed, sufficiently supported, validated transactions: save automatically.
- Failed/declined transactions: excluded from financial totals, with an appropriate correction path.
- Pending transactions: excluded until completion is established.
- Clear informational/nontransaction messages: do not create financial movement.
- Ambiguous messages: review with prefilled available information and a concrete explanation.
- Temporary processing failure: retain a clearly identified pending task for bounded retries.
- If a completion message later arrives, reconcile safely without double counting.
- Users must be able to correct a wrongly understood transaction or move it into review.
- Review entries must be confirmable, editable, or excludable.
- Reports should explain that transactions awaiting review are not included in totals.

Do not silently drop ambiguous financial messages. Do not create transactions from clearly nonfinancial messages to satisfy an “everything analyzed” metric.

4.7 Retries and identity
- Prevent duplicate records and double counting.
- Recheck consent and ownership for every attempt and before import.
- Handle logout, account switching, offline recovery, quota limits, and delayed responses.
- Use bounded retries with visible failure states.
- Do not promise background retries where platform execution is unavailable.
- Avoid indefinite storage of orphaned or unowned captures.

5. STRENGTHEN THE REAL AI PIPELINE

Inspect the actual model, prompts, input sanitization, contextual information, structured response handling, and validators.

Improve measured understanding rather than merely lengthening the prompt or adding isolated keyword exceptions.

Build on existing test assets and add coverage for:
- Arabic and English.
- Different bank formats and relevant international formats.
- Completed, declined, pending, refunded, and reversed transactions.
- Balance notices, bill reminders, expected deposits, promotions, and OTPs.
- Mixed-content messages.
- Multiple amounts and currencies.
- Incoming/outgoing direction and own-account transfers.
- Fees, VAT, tips, charged versus original amounts.
- Merchant names containing currency-like tokens.
- Truncated, malformed, and instruction-bearing text.
- Out-of-distribution or unsupported messages.

Do not assume an ATM cash deposit is new income or that a transfer is internal without evidence.

Separate:
- Development examples used to tune the system.
- A held-out evaluation set not used during tuning.
- Real, permissioned, appropriately redacted messages when available.
- Synthetic cases.

Do not label synthetic tests as real-world accuracy.

Run the actual configured AI model through the relevant application/backend path using existing authorized test access and a bounded budget. Do not create new paid services or increase billing commitments. If no authorized test budget/access exists, prepare the reproducible runner and report that specific blocker.

Measure:
- Nontransactions incorrectly saved as money movement.
- Incorrect amount, currency, direction, or status.
- Valid transactions lost or unnecessarily sent to review.
- Duplicate financial effects.
- Correct AI responses rejected by validators.
- Latency, request volume, and estimated cost.

Compare local-only and AI-enabled paths against the same ground truth.

Inspect tests that encode known incorrect outcomes. Clearly separate characterization tests from desired-behavior acceptance tests. Do not count “the known bug still happens” as proof of correctness.

Define and document justified acceptance criteria before final held-out evaluation. Do not invent owner-approved risk tolerances.

Do not keep adding regex patches to match a benchmark while causing regressions elsewhere. Prefer coherent semantic handling and safe review fallback.

If the current model is inadequate, compare suitable alternatives on the same evaluation with cost, latency, privacy implications, and integration impact. Do not silently change providers or data recipients.

6. CLOSE REMAINING IN-SCOPE RELEASE DEFECTS

Use the existing issue register as the work queue.

Prioritize:
- Incorrect financial effects.
- Data loss, duplication, and account isolation.
- Restore/sync correctness.
- Consent and unintended transmission.
- Account deletion and profile-photo cleanup.
- iOS capture/import/notification consistency.
- Release-build configuration and CI correctness.
- Privacy declarations and actual data behavior.
- Operational recovery, monitoring, and AI-cost controls.

Review outstanding required-reason API declarations and store documentation against current official sources. Do not rely on remembered codes or outdated model knowledge.

Assess the admin dependency/security findings on the actual installed dependency tree and deployment exposure. Implement an appropriate supported fix and verify affected behavior; do not assume a previous patch-version bump resolved every advisory.

Address accessibility, touch targets, contrast, Arabic/English layout, and large text using the current design system. Do not cap accessibility text scaling simply to make tests pass.

Preserve existing approved functionality. Do not introduce unrelated redesigns or dormant-feature activation.

For every remaining S1/S2:
- Fix and verify it;
- Demonstrate with evidence that it is not applicable;
- Or identify the exact unresolved blocker.

Do not downgrade severity merely to obtain READY.
Do not treat these product decisions as acceptance of unrelated defects or limitations.

7. PRODUCTION AND OPERATIONAL PREPARATION

Read-only production inspection is allowed where access is available and authorized. Redact secrets and personal data.

Verify the current production state against the final candidate, not an older intermediate commit.

The previous plan named:
- account-deletion-worker
- process-ios-sms
- parse-sms

Verify that this is still the correct deployment scope. Do not assume it is complete or unchanged.

Verify migration state using appropriate evidence. Matching migration IDs alone are not proof of complete schema equivalence.

Prepare:
- Exact function/config changes and deployment order.
- Required environment/secret names, without exposing values.
- Ads flag changes.
- Smoke tests.
- Monitoring signals and actionable failure criteria.
- Rollback sources and commands matched to the deployed versions.
- A verified backup/recovery assessment.
- A global AI-spend containment strategy, beyond easily multiplied per-device caps.

Do not assume backup or point-in-time recovery exists. Do not enable paid recovery services, export production data, or change retention without authorization.

Do not combine unreviewed permission/grant changes with unrelated deployment steps. Ensure any proposed rollback restores the actual previous state.

Test compatibility between:
- Old app / old backend.
- Old app / new backend.
- New app / old backend.
- New app / new backend.

Include relevant Cloud/AI consent modes.

A simultaneous rollout is not a compatibility strategy: existing build 147 users may remain active after deployment. Do not rely on an unverified force-update mechanism.

No production mutations, function deployments, flag changes, migrations, grants, data cleanup, push, merge, or store upload/submission are authorized yet.

8. VERIFICATION AND RELEASE CANDIDATE

Validate the final integrated application/test tree.

Run the required local release gates and appropriate behavioral tests, including:
- Flutter tests and static analysis.
- Relevant native iOS tests.
- Backend behavior, not only static contracts.
- Real local-stack restore/sync/deletion scenarios.
- Actual AI evaluation where authorized access exists.
- Arabic/English UI and accessibility checks.
- Capture → analysis → category → persistence → notification → reporting.
- Offline recovery, retries, consent withdrawal, account switching, and deduplication.

Use before/after regression evidence for meaningful fixes where feasible.

Inspect skipped tests. Do not weaken assertions, hide failures, or silently expand exclusions.

Build an installable iPhone candidate where tooling and signing allow. Preserve user/device data.

Run physical-device and CI verification only when access and required authorization exist. If a CI run requires a push, prepare the exact commit and request that push as a separate approval.

A simulator is not a physical device.
A local gate run is not CI.
A contract test is not a signed release build.
An AI review is not a human or store approval.

Independently review the final integrated changes, including regression risks and evidence quality. Restrict additional review rounds to material changes and unresolved findings; do not restart broad audits indefinitely.

9. DOCUMENTATION AND HANDOFF

Maintain the existing reusable release process and V1 folder. Avoid unnecessary new documents.

Update and reconcile:
- RELEASE-MANIFEST.md
- RELEASE-DECISION.md
- DECISIONS-NEEDED.md
- ISSUES.md
- REVIEW-CLOSURE.md
- KNOWN-LIMITATIONS.md
- RELEASE-PLAN.md
- CHANGELOG.md
- Test, AI-evaluation, device, and production-comparison evidence.

Record these owner decisions as approved. Distinguish them from your implementation assumptions and unresolved external requirements.

Keep counts and statuses consistent. Distinguish:
- Implemented locally.
- Verified locally.
- Verified on CI.
- Verified on a physical device.
- Deployed.
- Externally blocked.
- Explicitly deferred from V1.

Use a precise commit/build identity for every important result. Distinguish app/test changes from documentation-only commits. State whether the final working tree is clean.

Make small coherent local commits where appropriate. Do not push or merge.

Provide concise progress updates focused on outcomes and remaining blockers. Do not interrupt for routine choices.

Your final response must be in clear Egyptian Arabic and contain:
1. What is implemented and verified.
2. AI understanding results before/after, including remaining weaknesses and test-set limitations.
3. Exact final candidate identity and build status.
4. Remaining release blockers with concrete reasons.
5. A single consolidated list of required owner actions/access.
6. A concrete production change package ready for approval.
7. Links to the updated evidence.

Give a candid READY or NOT READY recommendation based on verified evidence. Do not promise a flawless AI system or claim readiness from test counts alone.

Begin by inspecting the current branch and release records, then execute the work. Do not stop after proposing a plan.
