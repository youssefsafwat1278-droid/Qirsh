import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../domain/entities/transaction_entity.dart';
import '../../domain/services/shared_category_learning.dart';

/// Sends user-confirmed merchant rules ("Remember for this merchant") to the
/// `merchant-category-contribution` Edge Function, where enough distinct users
/// agreeing makes a candidate an admin may publish to the shared catalog.
///
/// A send needs ALL of: a signed-in account ([accountUid]), that account's
/// "Help improve categories for everyone" opt-in ([optedIn], OFF by default),
/// and Cloud AND AI consent ([mayEgress], `EgressClass.aiProcessing`). All are
/// checked when a rule is offered AND again right before every send, against
/// the account that offered it. Any refusal at send time drops everything
/// queued, so turning the opt-in or either consent OFF (or switching account)
/// can never let an earlier contribution out later. The queue lives only in
/// memory and a failed send is not retried. Turning the opt-in ON sends
/// nothing by itself: only rules confirmed afterwards are offered.
class SharedCategoryLearningClient {
  SharedCategoryLearningClient({
    required String? Function() accountUid,
    required Future<bool> Function(String uid) optedIn,
    required Future<bool> Function() mayEgress,
    required Future<void> Function(Map<String, String> body) send,
  })  : _accountUid = accountUid,
        _optedIn = optedIn,
        _mayEgress = mayEgress,
        _send = send;

  /// The production transport. Only a signed-in user can contribute — the
  /// server counts users, not devices.
  factory SharedCategoryLearningClient.supabase(
    supabase.SupabaseClient client, {
    required Future<bool> Function(String uid) optedIn,
    required Future<bool> Function() mayEgress,
  }) =>
      SharedCategoryLearningClient(
        accountUid: () => client.auth.currentUser?.id,
        optedIn: optedIn,
        mayEgress: mayEgress,
        send: (body) => client.functions
            .invoke('merchant-category-contribution', body: body),
      );

  final String? Function() _accountUid;
  final Future<bool> Function(String uid) _optedIn;
  final Future<bool> Function() _mayEgress;
  final Future<void> Function(Map<String, String> body) _send;
  final _queue = <(String, SharedCategoryContribution)>[];
  bool _flushing = false;

  int get queuedCount => _queue.length;

  /// Drops anything queued — called when the user turns the opt-in OFF.
  void dropQueued() => _queue.clear();

  Future<bool> _allowedFor(String uid) async =>
      _accountUid() == uid && await _optedIn(uid) && await _mayEgress();

  /// Offers the rule the user just confirmed. Ineligible rows (transfers,
  /// people, identifiers) are dropped here, before anything is queued.
  Future<void> offer(TransactionEntity transaction, String categoryKey) async {
    final contribution = sharedContributionFor(transaction, categoryKey);
    if (contribution == null) return;
    final uid = _accountUid();
    if (uid == null || uid.isEmpty || !await _allowedFor(uid)) return;
    _queue
      ..removeWhere((c) => c.$2.merchantKey == contribution.merchantKey)
      ..add((uid, contribution));
    await flush();
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final (uid, next) = _queue.first;
        if (!await _allowedFor(uid)) {
          _queue.clear();
          return;
        }
        _queue.removeAt(0);
        try {
          await _send(next.toJson());
        } catch (_) {
          // Best effort: the shared catalog is an improvement, not a duty.
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
