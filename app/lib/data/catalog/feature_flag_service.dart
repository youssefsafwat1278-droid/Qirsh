import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'catalog_daos.dart';

/// Safe defaults — used when a flag is missing, inactive, or sync has not run.
/// Every flag key that the app references must appear here.
const Map<String, Object> _defaults = {
  'enable_goals': true,
  'enable_coupons': false,
  // Referral discovery/UI rollout gate (docs REFERRAL_REWARDS_SYSTEM.md §19/§24).
  // Seeded OFF, fails closed. The SERVER enforces attribution/qualification
  // independently via an active rule — this flag governs client discovery only.
  'enable_referrals': false,
  // Report-export interstitial placement gate (docs REPORT_ADS §14, R4). Seeded
  // OFF, fails closed. Product-placement rollout only — never a financial
  // capability authority; the entitlement decision is server-authoritative.
  'enable_report_ads': false,
  // BANNER ads. Two flags, not one: the master turns the whole format off, and
  // the per-placement flag turns ONE surface off without taking the format with
  // it. Both seeded OFF and fail-closed.
  //
  // Every placement key referenced by `bannerPlacementEnabledProvider` must
  // appear here. `getBool` consults the remote cache first and only falls back
  // to this map, so a key present in neither is false by accident rather than
  // by decision — and "false by accident" is indistinguishable from "off" right
  // up until someone flips it remotely and nothing happens.
  //
  // One key per `AdPlacement`, ALL false — including the surfaces added by
  // D-19 (2026-09-19). Seeding a new placement `true` would look like a
  // rollout and behave like the opposite: `getBool` falls back to this map for
  // anyone the percentage bucket excludes, so a `true` default hands the
  // feature to exactly the users a partial rollout was meant to hold back.
  // A guard test enforces `false` for every placement, not merely presence.
  'enable_banner_ads': false,
  'enable_banner_transactions_list': false,
  'enable_banner_dashboard': false,
  'enable_banner_goals': false,
  'enable_banner_subscriptions': false,
  'enable_banner_reports': false,
  'enable_banner_achievements': false,
  // COUPONS Phase 1+ — four INDEPENDENT kill switches, all seeded OFF and
  // fail-closed. Deliberately not one flag: `enable_coupons` remains the master
  // for the generic catalog, and if merchant awareness, tracked links or
  // savings has to be switched off, the catalog must keep working. A single
  // flag that disables everything is an outage, not a kill switch.
  //
  // The merchant catalog, merchant pages and the For You section.
  'enable_offers_merchants': false,
  // Whether the local personalization TOGGLE is offered at all. The toggle
  // itself is the user's choice and is stored locally; this only decides
  // whether they are asked.
  'enable_offers_personalization': false,
  // The tracked affiliate CTA path (Phase 3). Off means every CTA is a plain
  // untracked link, which still works.
  'enable_affiliate_links': false,
  // Savings claims and the savings surfaces (Phase 4).
  'enable_savings_claims': false,
  'enable_announcements': true,
  'parser_engine_version': 'v1',
  // PHASE 11 — Proof-carrying autocommit. Seeded OFF and shipped OFF.
  //
  // This is the REMOTE KILL SWITCH. With it false the Proof gate runs in shadow
  // and the commit decision is byte-identical to what it would be without
  // Proof, so turning it off can never leave a capture in a state the
  // deterministic pipeline could not have produced.
  //
  // Note the gate is SUBTRACTIVE: armed, it can only send an auto-confirmation
  // to review, never create one. Enabling it cannot cause a false commit; the
  // worst it can do is ask a human about a correct capture.
  'enable_proof_autocommit': false,
  // Floor for the armed gate, in permille, applied to the DETERMINISTIC
  // PARSER's confidence. Named for the parser because ProofResult carries a
  // verdict enum and no numeric confidence — `proof_confidence_min` implied a
  // number that does not exist and would have become a false contract the
  // moment anyone tuned it. Never activated, so no migration is needed.
  //
  // 990 is far above the deterministic auto-confirm bar of 0.92 on purpose:
  // that bar decides "probably right", this one decides "safe to never show
  // anyone".
  'proof_parser_confidence_min': 990,
  'ledger_dual_write': false,
  'ledger_pull_sync': false,
  'ledger_push_sync': false,
  'smart_inbox_pull_sync': false,
  'planning_accounts_sync': false,
  'planning_budgets_sync': false,
  'planning_subscriptions_sync': false,
  'planning_goals_sync': false,
  'planning_plans_sync': false,
  'capture_direct_ledger_write': false,
  // Kill switch: lets a durable native capture the backend failed to analyse
  // use the in-app AI fallback (still consent-gated). Seeded OFF.
  'capture_ai_fallback_enabled': false,
  // OPERATOR KILL SWITCH for automatic in-app AI analysis of Android captures.
  // Compiled ON: Android has no native upload pipeline, so this is the only
  // automatic analysis its captures get, and it still needs the user's Cloud
  // AND AI consent (read fresh before every request). To switch it off for
  // everyone, publish this key ACTIVE with value `false` at rollout 100 —
  // `init()` lets an in-rollout remote value override this default. A missing,
  // inactive or partial-rollout row leaves it ON for the excluded installs.
  'android_capture_ai_enabled': true,
  // CAP-5: the single iOS capture import (CaptureImportService, bound to the
  // account scope) with local-after-reject (Q5) and no app-side AI. Seeded OFF;
  // OFF is the shipped relay + native-drain import, byte for byte.
  'capture_import_v3': false,
  // CAP-7: the notification journey (push_attempted owner rule, generic text on
  // every channel, backlog summary, corrections). Seeded OFF; OFF is the shipped
  // notification behaviour, byte for byte.
  'capture_notify_v2': false,
  // CAP-7: shared notification identifiers (remote collapse-id == local request
  // id). Only after the T-N4 device proof; seeded OFF and nothing reads it yet.
  'capture_notify_shared_ids': false,
  // Binary local acceptance: a capture the local parser reads as VALID is
  // confirmed (no pending stage); an INVALID one is treated as "local produced
  // no transaction" (AI + validator when allowed, else Smart Inbox). Seeded OFF;
  // OFF is the legacy confidence/pending behaviour, byte for byte.
  'local_auto_confirm_v2': false,
  // A validated AI capture whose bank matched exactly one catalog bank
  // persists a sender->bank mapping (accepted_by='ai_validated'). Stays OFF
  // until migration 0100 (sender_bank_mappings.accepted_by) is deployed.
  'ai_sender_mapping_auto': false,
  // MALI-034: the obsolete Supabase-primary financial-authority flags
  // (accounts/transactions/budgets/goals/subscriptions/plans_supabase_primary,
  // smart_inbox_supabase_primary, dashboard_supabase_summary,
  // budget_progress_supabase_rpc, capture_direct_supabase_write) were removed.
  // Drift is the sole normal financial CRUD authority; a stale remote key for
  // any of them resolves into _cache but is read by no code (getBool returns
  // false for unknown keys), so it can no longer switch authority.
};

/// Keys a per-user override must never force: they are server-controlled
/// (admin flag control plane); an override row for them is ignored.
const Set<String> _overrideIgnoredKeys = {
  'enable_proof_autocommit',
  'ai_sender_mapping_auto',
};

class FeatureFlagService {
  FeatureFlagService({
    required RemoteFeatureFlagsDao dao,
    required String installId,
  })  : _dao = dao,
        _installId = installId;

  final RemoteFeatureFlagsDao _dao;
  final String _installId;

  // In-memory cache populated by init(). Safe defaults are used until init runs.
  final Map<String, Object> _cache = Map.of(_defaults);

  bool _initialised = false;

  /// Load all flags from Drift and compute rollout buckets.
  /// Must be called after seed/sync. Safe to call multiple times.
  Future<void> init() async {
    try {
      final flags = await _dao.getAllActiveFlags();
      final sha = Sha256();
      final resolved = <String, Object>{};
      for (final flag in flags) {
        final value = await _resolveFlag(flag, sha);
        if (value != null) resolved[flag.key] = value;
      }
      _cache
        ..clear()
        ..addAll(_defaults)
        ..addAll(resolved);
      _initialised = true;
    } catch (e, st) {
      debugPrint('FeatureFlagService.init failed: $e');
      debugPrintStack(stackTrace: st);
    }
  }

  bool get isInitialised => _initialised;

  /// يجلب overrides الخاصة بالمستخدم الموقّع دخوله حاليًا من
  /// feature_flag_overrides على Supabase مباشرة (لا كاش محلي — القيمة
  /// المقصودة لهذه الآلية أن تكون شبه فورية لأغراض QA/الطرح التدريجي لكل
  /// مستخدم) وتُطبَّق فوق نتيجة rollout العادية. لا تأثير على المستخدمين
  /// الآخرين ولا على rollout_percent العام.
  Future<void> applyUserOverrides(SupabaseClient supabaseClient, String? userId,
      {bool Function()? isCurrent}) async {
    if (userId == null) return;
    try {
      final rows = await supabaseClient
          .from('feature_flag_overrides')
          .select('key, enabled')
          .eq('user_id', userId);
      if (isCurrent != null && !isCurrent()) return;
      for (final row in rows) {
        final key = row['key'] as String?;
        final enabled = row['enabled'];
        if (key != null &&
            enabled is bool &&
            !_overrideIgnoredKeys.contains(key)) {
          _cache[key] = enabled;
        }
      }
    } catch (e) {
      debugPrint(
        'FeatureFlagService.applyUserOverrides failed: ${e.runtimeType}',
      );
    }
  }

  bool getBool(String key) {
    final v = _cache[key];
    if (v is bool) return v;
    return _defaults[key] is bool ? _defaults[key] as bool : false;
  }

  String getString(String key) {
    final v = _cache[key];
    if (v is String) return v;
    return _defaults[key] is String ? _defaults[key] as String : '';
  }

  int getInt(String key) {
    final v = _cache[key];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return _defaults[key] is num ? (_defaults[key] as num).toInt() : 0;
  }

  Object? getJson(String key) {
    return _cache[key] ?? _defaults[key];
  }

  Future<Object?> _resolveFlag(RemoteFeatureFlag flag, Sha256 sha) async {
    if (!flag.isActive) return null;

    final bool inRollout;
    if (flag.rolloutPercent >= 100) {
      inRollout = true;
    } else if (flag.rolloutPercent <= 0) {
      inRollout = false;
    } else {
      // SHA-256("$installId:$key") → first 2 bytes → uint16 % 100
      final hash = await sha.hash(
        utf8.encode('$_installId:${flag.key}'),
      );
      final bucket = ((hash.bytes[0] << 8) | hash.bytes[1]) % 100;
      inRollout = bucket < flag.rolloutPercent;
    }

    if (!inRollout) return null;

    switch (flag.valueType) {
      case 'boolean':
        return flag.value.toLowerCase() == 'true';
      case 'number':
        return num.tryParse(flag.value);
      case 'string':
        return flag.value;
      case 'json':
        try {
          return jsonDecode(flag.value) as Object?;
        } catch (_) {
          return null;
        }
      default:
        return null;
    }
  }
}
