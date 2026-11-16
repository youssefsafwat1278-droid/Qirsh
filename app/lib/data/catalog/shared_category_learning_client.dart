import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../domain/entities/transaction_entity.dart';
import '../../domain/services/shared_category_learning.dart';

/// Sends user-confirmed merchant rules ("Remember for this merchant") to the
/// `merchant-category-contribution` Edge Function, where enough distinct users
/// agreeing makes a candidate an admin may publish to the shared catalog.
///
/// Consent: [mayEgress] must answer Cloud AND AI consent
/// (`EgressClass.aiProcessing`). It is asked when a rule is offered AND again
/// right before every send. A refusal at send time drops everything queued, so
/// withdrawing either consent can never let an earlier contribution out later.
/// The queue lives only in memory and a failed send is not retried: nothing is
/// persisted that would outlive the moment the user made the choice.
class SharedCategoryLearningClient {
  SharedCategoryLearningClient({
    required Future<bool> Function() mayEgress,
    required Future<void> Function(Map<String, String> body) send,
  })  : _mayEgress = mayEgress,
        _send = send;

  /// The production transport. Only a signed-in user can contribute — the
  /// server counts users, not devices.
  factory SharedCategoryLearningClient.supabase(
    supabase.SupabaseClient client, {
    required Future<bool> Function() mayEgress,
  }) =>
      SharedCategoryLearningClient(
        mayEgress: () async =>
            client.auth.currentUser != null && await mayEgress(),
        send: (body) => client.functions
            .invoke('merchant-category-contribution', body: body),
      );

  final Future<bool> Function() _mayEgress;
  final Future<void> Function(Map<String, String> body) _send;
  final _queue = <SharedCategoryContribution>[];
  bool _flushing = false;

  int get queuedCount => _queue.length;

  /// Offers the rule the user just confirmed. Ineligible rows (transfers,
  /// people, identifiers) are dropped here, before anything is queued.
  Future<void> offer(TransactionEntity transaction, String categoryKey) async {
    final contribution = sharedContributionFor(transaction, categoryKey);
    if (contribution == null) return;
    if (!await _mayEgress()) return;
    _queue
      ..removeWhere((c) => c.merchantKey == contribution.merchantKey)
      ..add(contribution);
    await flush();
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        if (!await _mayEgress()) {
          _queue.clear();
          return;
        }
        final next = _queue.removeAt(0);
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
