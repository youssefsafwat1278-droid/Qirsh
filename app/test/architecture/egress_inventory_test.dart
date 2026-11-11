import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// C-3 / R-1 — no new network egress without a consent decision.
///
/// ## Why a structural test and not only unit tests
/// The root cause of F-025 was never a missing check in one place. It was that
/// consent enforcement was **per-service opt-in**, so every new service shipped
/// ungated by default — and several did. Two found in review, both shipped:
///
///   * `RemoteBackupController` defaulted its consent callback to `() => true`
///     and the provider never passed one, so the encrypted backup uploaded with
///     cloud consent OFF;
///   * the Smart Inbox pull gate is a hardcoded `isPullEnabled: () => true`.
///
/// Unit tests prove the gates that EXIST work. Only an inventory test can catch
/// the next service that forgets one. This is the R-1 structural remedy: every
/// file that talks to the network must be a deliberate, listed decision.
///
/// ## How to satisfy it when it fails
/// Adding egress to a new file will fail this test. That is the point. Either
/// gate the call through `ConsentAuthority` and add the file to [_gated], or —
/// if it genuinely carries no user data — add it to [_ungatedByDesign] WITH the
/// reason. Do not add a file to the ungated list to make the test pass.
void main() {
  /// Files whose egress is gated on consent, and where.
  const gated = <String, String>{
    'data/sync/sender_bank_mapping_sync_service.dart':
        'EgressClass.senderBankMappings — which banks the user holds',
    'features/planning_sync/services/accounts_push_service.dart':
        'EgressClass.financialSync — money',
    'features/capture/services/ledger_push_service.dart':
        'EgressClass.financialSync — money',
    'data/sync/server_capabilities.dart':
        'EgressClass.financialSync — read-only capability RPC, consent-gated '
            'via injected mayEgress (A-6 awaiting-FX probe)',
    'features/capture/services/notification_log_sync_service.dart':
        'EgressClass.telemetry — notification delivery/open events',
    'features/capture/services/smart_inbox_sync_service.dart':
        'EgressClass.smartInbox — its isPullEnabled is a FEATURE gate, '
            'hardcoded open; consent is asked separately',
    'data/catalog/merchant_feedback_client.dart':
        'EgressClass.aiProcessing — user-derived merchant keywords. Unwired '
            'today; gated now so whoever wires it must pass consent',
    'features/planning_sync/services/accounts_pull_service.dart':
        'EgressClass.financialSync — money DOWN; a pull also WRITES locally',
    'features/planning_sync/services/planning_pull_service.dart':
        'EgressClass.financialSync — gated once per pull, not per entity',
    // ── All four surfaced 2026-09-16, when the guard learned to see a
    //    receiver on its own line. Three were correctly gated all along and
    //    simply invisible; the fourth was not gated at all.
    'features/planning_sync/services/planning_push_service.dart':
        'EgressClass.financialSync — money. Gated by the sync engine, whose '
            '`mayEgress` covers every push it drives',
    'features/planning_sync/services/planning_server_currency_repair.dart':
        'EgressClass.financialSync — same engine, same gate as the push above',
    'data/sync/revision_cas.dart':
        'EgressClass.financialSync — the WP-5 CAS RPC transport shared by the '
            'push services; each asks its own `mayEgress` before plan()/any RPC',
    'core/di/rebootstrap_providers.dart':
        'EgressClass.financialSync — the rebootstrap runs only after the consent-gated replica_epoch probe',
    'data/sync/seq_pull.dart':
        'EgressClass.financialSync — the WP-4 sequence-pull transport shared by '
            'the pull services; every caller asks its own consent gate before '
            'it calls plan()/fetch(), and the gate itself holds no consent',
    'features/capture/services/ledger_sync_service.dart':
        'EgressClass.financialSync — the ledger pull, gated by its caller',
    'core/tracking/user_activity_service.dart':
        'EgressClass.profileAndSettings — profiles.last_seen_at, i.e. when this '
            'person opened a money app. Was UNGATED on every cold start. The '
            'service is static and cannot reach the database, so the gate is '
            'injected from bootstrap and DEFAULTS CLOSED: an unconfigured build '
            'transmits nothing',
    'data/catalog/catalog_sync_service.dart':
        'EgressClass.catalog — Astra G (P1) REMOVED the former "never gated" '
            'exemption: no automatic catalog fetch while Cloud is OFF. Gated by '
            'its caller (syncCatalog) through CloudEgressGate.permits(), by '
            'syncAll itself, and below both by the gated Supabase transport.',
    'features/gamification/services/gamification_sync_service.dart':
        'EgressClass.gamification — achievements, streaks and XP, derived from '
            'what this person did in the app. Was UNGATED and LEAKING: observed '
            'at runtime fetching all three with cloud consent OFF. Gated '
            '2026-09-16, and the constructor defaults CLOSED so a caller that '
            'forgets the gate gets no egress rather than silent egress',
    'features/planning_sync/services/planning_child_sync_service.dart':
        'EgressClass.financialSync — consent precedes the capability gate',
    'features/planning_sync/services/accounts_backfill_service.dart':
        'EgressClass.financialSync — money. Gated by its CALLER, '
            'StartupSyncReconcileService, whose single check covers every '
            'backfill it drives. Was an OPEN finding until 2026-09-02: it '
            'gated on transport capability and never on consent.',
    'core/backup/supabase_remote_backup_store.dart':
        'EgressClass.backup — gated by its CALLER, RemoteBackupController',
    'core/backup/encrypted_backup_service.dart':
        'EgressClass.backup — gated by its CALLER, RemoteBackupController',
    'features/coupons/coupon_analytics.dart':
        'cloudProcessingEnabled, re-read per send (coupon_analytics.dart:99) — '
            'record_coupon_event carries a coupon id and an event name and no '
            'financial context. Surfaced only when this guard learned to see '
            '`.rpc<T>(`; it was correctly gated the whole time, but nothing '
            'was enforcing that.',
  };

  /// Where the gate lives, when it is not in the egress file itself.
  ///
  /// A store that performs the upload is not always the right place to ask the
  /// question — the backup store is driven exclusively by
  /// `RemoteBackupController`, which is where the consent decision belongs.
  /// Recording the indirection keeps the check honest instead of loosening it.
  const gatedByCaller = <String, String>{
    // WP-4: the sequence-pull transport holds no consent itself; each pull
    // service asks its own gate first (accounts is the representative caller).
    'data/sync/seq_pull.dart':
        'features/planning_sync/services/accounts_pull_service.dart',
    // WP-5: the CAS transport holds no consent itself; every push service asks
    // its own gate first (accounts is the representative caller).
    'data/sync/revision_cas.dart':
        'features/planning_sync/services/accounts_push_service.dart',
    // CLOSED 2026-09-02 (was an OPEN finding). The backfills reached from
    // StartupSyncReconcileService gated on TRANSPORT capability and never on
    // consent, while every sibling push/pull service in the same pipeline
    // asked. A transport gate answers "can we send this safely"; it does not
    // answer "may we". ONE gate at the reconcile entry covers every backfill it
    // drives, and it defaults to DENY.
    'features/planning_sync/services/accounts_backfill_service.dart':
        'features/planning_sync/services/startup_sync_reconcile_service.dart',
    'core/backup/supabase_remote_backup_store.dart':
        'core/backup/remote_backup_controller.dart',
    'core/backup/encrypted_backup_service.dart':
        'core/backup/remote_backup_controller.dart',
    // WP-7: the rebootstrap runs only after EpochRebootstrapTrigger probed the
    // `replica_epoch` capability, which is consent-gated (financialSync).
    'core/di/rebootstrap_providers.dart': 'core/di/app_providers.dart',
    // The planning/ledger engines hold one gate for the whole pipeline; the
    // individual services are reached only through them.
    'features/planning_sync/services/planning_push_service.dart':
        'core/di/app_providers.dart',
    'features/planning_sync/services/planning_server_currency_repair.dart':
        'core/di/app_providers.dart',
    'features/capture/services/ledger_sync_service.dart':
        'core/di/app_providers.dart',
    // Static service, no DI — the gate is wired once during bootstrap.
    'core/tracking/user_activity_service.dart':
        'core/startup/bootstrap_runner.dart',
    'data/catalog/catalog_sync_service.dart': 'core/di/app_providers.dart',
  };

  /// Files whose egress runs only inside an operation-scoped account-control
  /// grant (`CloudEgressGate.runAccountControl`): an explicit user action,
  /// endpoint-allowlisted in `kAccountControlAllowlist`, time-boxed, and denied
  /// by the gated transport outside the grant. NOT a consent exemption: the
  /// test below binds every call in these files to that runtime allowlist, so a
  /// new endpoint cannot be added here without also being admitted there.
  const accountControl = <String, String>{
    'core/auth/supabase_auth_service.dart':
        'Google sign-UP only: `google-enrollment` gets the Google ID token and '
            'hashed nonce on the explicit "create account" tap, inside '
            'AccountControlOp.signIn (account_control_test pins that no other '
            'op can reach it).',
  };

  /// Files that reach the network WITHOUT a consent gate, each with the reason.
  ///
  /// Everything here is either genuinely consent-exempt, or an OPEN finding
  /// that is tracked rather than hidden. The distinction is stated per entry so
  /// nobody has to guess which is which.
  const ungatedByDesign = <String, String>{
    // ── Surfaced when `.rpc[<(]` was added to the pattern below ────────────
    //
    // Five call sites had been invisible to this guard since it was written:
    // the regex matched `functions.invoke` and `.from(` but not `.rpc(`, and
    // not `.rpc<void>(` even after the first widening. Each is classified here
    // on its merits. Two are OPEN FINDINGS, recorded rather than papered over.
    'core/auth/account_deletion_service.dart':
        'EXEMPT: request_account_deletion / cancel_account_deletion. Deletion '
            'must work regardless of consent state — gating the exit behind the '
            'permission would trap a user who wants their data gone. Carries no '
            'payload beyond the authenticated identity. Astra G: request and '
            'cancel run as an operation-scoped account-control grant (runAccountControl), the one '
            'escalated non-automatic exception besides interactive sign-in.',
    'core/session/app_session.dart':
        'EXEMPT: mark_onboarding_completed takes no parameters, is guarded on a '
            'live session and a non-guest account, and records account state '
            'rather than anything derived from the user.',
    'features/referrals/services/referral_service.dart':
        'EXEMPT: authenticated referral RPCs (0083), every one user-initiated. '
            'The only payload is a referral code the user typed. Server-side '
            'rules enforce qualification independently.',
    'core/backend/metrics_client.dart':
        'OPEN FINDING — not exempt. record_metric is best-effort product '
            'telemetry with NO consent gate. Mitigated but not resolved: the '
            'RPC is owner-bound, allowlisted and rate-limited server-side '
            '(MALI-075n), unknown keys are silent no-ops, and it sends a key '
            'plus a coarse dimension rather than user data. It is awaited from '
            'bootstrap, so a consent read there would need to survive a cold '
            'start with no settings loaded. Tracked, not hidden. Astra G: it '
            'now goes through the gated Supabase transport, so it is denied '
            'while Cloud is OFF / DISABLING / uncertain.',

    'features/gamification/services/engagement_event_service.dart':
        'OPEN FINDING — unwired, not exempt. SupabaseEngagementRecorder is '
            'declared but instantiated nowhere in lib/; grep finds no caller, '
            'so nothing reaches the network today. EgressClass.gamification '
            'already exists in ConsentAuthority and returns the cloud decision, '
            'so whoever wires this must gate it there and move this entry into '
            '`gated`. Listed the same way merchant_feedback_client.dart is, so '
            'the obligation is visible before the first caller appears.',
    // ── Surfaced 2026-09-16 when the line-break form was added ────────────
    'core/di/app_providers.dart':
        'EXEMPT: the composition root. It constructs the gated services and '
            'passes each its ConsentAuthority; the matches here are those '
            'wirings, not egress of its own.',
    'core/diagnostics/duplicate_trace_service.dart':
        'EXEMPT: reads user_accounts / user_transactions, but its only caller '
            'is behind `if (kDebugMode && !_didDupTrace)` in app_shell.dart, so '
            'it does not exist in a release build. Listed rather than ignored '
            'because the tables it reads are financial — if it is ever called '
            'outside that guard it must move to `gated`.',
  };

  test('every file that reaches the network is a listed decision', () {
    final egressCall = RegExp(
      r"functions\.invoke|\.storage\.from\(|http\.post|http\.get|"
      r"client\.from\(|_client\.from\(|supabase\.from\(|instance\.client\.from\(|"
      // COUPONS Phase 1 — `.rpc(` was a structural blind spot. A Supabase RPC
      // is a network call like any other, and coupon_analytics.dart has been
      // making one (`record_coupon_event`) that this guard could not see. Any
      // future RPC — an affiliate click, a status poll — would have been
      // equally invisible.
      r"\.rpc[<(]|"
      // 2026-09-16 — the LINE-BREAK blind spot, found at runtime rather than
      // by reading. Every alternative above requires the receiver and the call
      // on ONE line. `dart format` puts a long chain's receiver on its own
      // line, so
      //
      //     final rows = await supabase
      //         .from('user_achievements')
      //
      // matched nothing, and SEVEN files were invisible to this guard — not a
      // corner case, a whole formatting style. One of them,
      // gamification_sync_service.dart, was fetching achievements, streaks and
      // XP with cloud consent OFF; it was caught by driving the app with an
      // HttpOverrides recorder installed, which is what
      // `integration_test/cloud_off_egress_test.dart` now does on every run.
      //
      // The lesson is not "add this pattern". It is that a source-text guard
      // can only see the shapes it was told about, so it needs a runtime
      // counterpart that observes behaviour instead of spelling.
      r"(?:supabase|client|_client|_supabase|instance\.client)\s*\n\s*\.(?:from|rpc)[<(]",
      multiLine: true,
    );

    final found = <String>{};
    void walk(Directory dir) {
      for (final e in dir.listSync()) {
        if (e is Directory) {
          walk(e);
        } else if (e is File && e.path.endsWith('.dart')) {
          if (egressCall.hasMatch(e.readAsStringSync())) {
            found.add(e.path.replaceFirst('lib/', ''));
          }
        }
      }
    }

    walk(Directory('lib'));

    final known = {
      ...gated.keys,
      ...ungatedByDesign.keys,
      ...accountControl.keys
    };
    final unlisted = found.difference(known);

    expect(
      unlisted,
      isEmpty,
      reason: 'New network egress found in files that make no consent '
          'decision:\n  ${unlisted.join('\n  ')}\n\n'
          'Gate it through ConsentAuthority and add it to `gated`, or add it '
          'to `ungatedByDesign` WITH the reason it is exempt. Do NOT add a '
          'file to the ungated list merely to make this test pass — that is '
          'the per-service opt-in habit this test exists to break.',
    );
  });

  test('the listed files still exist — the inventory cannot go stale', () {
    for (final path in {
      ...gated.keys,
      ...ungatedByDesign.keys,
      ...accountControl.keys
    }) {
      expect(File('lib/$path').existsSync(), isTrue,
          reason: '$path is listed but no longer exists; prune the inventory');
    }
  });

  test('account-control files reach only allowlisted functions, inside a grant',
      () {
    final gate =
        File('lib/core/privacy/cloud_egress_gate.dart').readAsStringSync();
    final invoke = RegExp(r"functions\s*\.invoke\(\s*'([^']+)'");
    for (final path in accountControl.keys) {
      final src = File('lib/$path').readAsStringSync();
      expect(src, contains('runAccountControl'),
          reason: '$path must run its egress inside an account-control grant');
      // Tables, RPCs, storage and raw HTTP have no place here at all.
      expect(
          RegExp(r"\.from\(|\.rpc[<(]|\.storage\.|http\.(post|get)")
              .hasMatch(src),
          isFalse,
          reason: '$path: only allowlisted Edge Functions may be called');
      // Every function call names a literal function, and that exact endpoint
      // is admitted by the runtime allowlist.
      final names = invoke.allMatches(src).map((m) => m.group(1)!).toList();
      expect(names, isNotEmpty, reason: path);
      expect(RegExp(r'functions\s*\.invoke\(').allMatches(src).length,
          names.length,
          reason: '$path: a function name must be a literal');
      for (final name in names) {
        expect(gate,
            contains("AccountControlEndpoint('POST', '/functions/v1/$name')"),
            reason: '$path calls `$name`, which kAccountControlAllowlist does '
                'not admit');
      }
    }
  });

  test('every ungated entry states a reason, and open ones say so', () {
    for (final entry in ungatedByDesign.entries) {
      expect(entry.value.trim(), isNotEmpty, reason: entry.key);
      expect(
        entry.value.startsWith('EXEMPT') || entry.value.startsWith('OPEN'),
        isTrue,
        reason: '${entry.key}: an ungated egress must be classified either '
            'EXEMPT (carries no user data) or OPEN (a tracked finding). '
            '"Undecided" is how ungated egress ships.',
      );
    }
  });

  test('the gated files actually reference the consent authority', () {
    // A file listed as gated that never consults consent would make this
    // inventory a comfortable fiction.
    for (final path in gated.keys) {
      // Check the file that actually holds the gate — which is the caller for
      // the backup store.
      final gateFile = gatedByCaller[path] ?? path;
      final src = File('lib/$gateFile').readAsStringSync();
      // `cloudProcessingEnabled` counts as a real gate, not a loophole: it is
      // the same effective grant ConsentAuthority derives its decision from,
      // and for a telemetry-class call the authority returns exactly that
      // value. Routing through the authority is still preferable — one place to
      // change the policy — so a new call site should use it rather than this.
      final gatedHere = src.contains('mayEgress') ||
          src.contains('ConsentAuthority') ||
          src.contains('consentGranted') ||
          src.contains('cloudProcessingEnabled');
      expect(gatedHere, isTrue,
          reason: '$path is listed as gated, but its gate file $gateFile '
              'references no consent check');
    }
  });
}
