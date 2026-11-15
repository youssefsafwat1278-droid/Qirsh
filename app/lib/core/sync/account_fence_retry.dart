import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// This partial unit handles raw structured refusals only. It neither revokes
/// account authority nor invents QD002/QD003 or wrapped-error handling.
class AccountFenceRetryStopped implements Exception {
  const AccountFenceRetryStopped();
  @override
  String toString() => 'AccountFenceRetryStopped';
}

/// One budget per outbox item, shared by its atomic remote mutations. Local
/// bookkeeping, reads, a whole item/cycle, and nested retry loops are not replayed.
class AccountFenceRetry {
  AccountFenceRetry({
    this.maxAttempts = 3,
    this.retryDelay = const Duration(milliseconds: 50),
    this.cooldown = const Duration(seconds: 30),
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : clock = clock ?? DateTime.now,
       delay = delay ?? Future<void>.delayed {
    if (maxAttempts < 1 || maxAttempts > 8 || retryDelay < Duration.zero ||
        cooldown <= Duration.zero) {
      throw ArgumentError('invalid_account_fence_budget');
    }
  }

  final int maxAttempts;
  final Duration retryDelay;
  final Duration cooldown;
  final DateTime Function() clock;
  final Future<void> Function(Duration) delay;
  static const _key = #accountFenceMutationBudget;

  /// Retry a standalone RPC whose 55P03 response means it rolled back.
  /// Recheck the original authority before each attempt, just like an outbox.
  Future<T> runMutation<T>({
    required Future<bool> Function() isCurrent,
    required Future<T> Function() send,
  }) => _FenceBudget(this, isCurrent).mutate(send);

  Future<T> runItem<T>({required Future<bool> Function() isCurrent,
      required Future<T> Function() body}) =>
      runZoned(() async => await body(), zoneValues: {
        _key: _FenceBudget(this, isCurrent),
      });
}

class _FenceBudget {
  _FenceBudget(this.policy, this.isCurrent);
  final AccountFenceRetry policy;
  final Future<bool> Function() isCurrent;
  int retries = 0;
  bool mutating = false;

  Future<T> mutate<T>(Future<T> Function() send) async {
    // Composite callers must not acquire a fresh nested budget.
    if (mutating) return send();
    mutating = true;
    try {
      while (true) {
        if (!await isCurrent()) throw const AccountFenceRetryStopped();
        try { return await send(); }
        on PostgrestException catch (error) {
          if (error.code != '55P03' || retries >= policy.maxAttempts - 1) rethrow;
          retries++;
          await policy.delay(policy.retryDelay);
        }
      }
    } finally {
      mutating = false;
    }
  }
}

/// Call at an atomic remote mutation boundary, with its already-captured
/// payload/identity/revision. Outside an outbox item's budget it sends once.
Future<T> retryAccountFenceMutation<T>(Future<T> Function() send) =>
    (Zone.current[AccountFenceRetry._key] as _FenceBudget?)?.mutate(send) ?? send();
