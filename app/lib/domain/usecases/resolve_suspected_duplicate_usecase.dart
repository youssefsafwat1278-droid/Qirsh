import '../entities/suspected_duplicate_entity.dart';
import '../entities/transaction_entity.dart';
import '../repositories/suspected_duplicate_repository.dart';
import 'add_transaction_usecase.dart';

/// The review actions of a suspected duplicate (the later of two captures
/// that may be one purchase). NONE of them deletes or edits the ORIGINAL
/// (existing) transaction:
///
/// - [dismiss] — "it is a duplicate": only the review flag is removed. The
///   original stays exactly as it was; the later capture adds nothing.
/// - [dismissAll] — the same for every listed flag.
/// - [keepBoth] — "save as new": they are separate purchases, so the later
///   capture becomes its own transaction next to the original.
class ResolveSuspectedDuplicateUseCase {
  const ResolveSuspectedDuplicateUseCase({
    required AddTransactionUseCase addTransaction,
    required SuspectedDuplicateRepository repository,
    required Future<void> Function(Future<void> Function() action)
        runAtomically,
  })  : _addTransaction = addTransaction,
        _repository = repository,
        _runAtomically = runAtomically;

  final AddTransactionUseCase _addTransaction;
  final SuspectedDuplicateRepository _repository;
  final Future<void> Function(Future<void> Function() action) _runAtomically;

  Future<void> dismiss(SuspectedDuplicateEntity dupe) =>
      _repository.delete(dupe.id);

  Future<void> dismissAll(Iterable<SuspectedDuplicateEntity> dupes) async {
    for (final dupe in dupes) {
      await _repository.delete(dupe.id);
    }
  }

  /// Adds the later capture as its own transaction, with the flag's id as its
  /// identity: a repeated tap or a retry after a crash finds that transaction
  /// instead of adding a third row. The flag is removed only once the
  /// transaction exists; when nothing could be added (unreadable, or the
  /// request was refused/failed) the flag stays so the capture is not lost.
  Future<AddTransactionResult> keepBoth(SuspectedDuplicateEntity dupe) async {
    final result = await _addTransaction(
      rawMessage: dupe.rawMessage,
      senderId: dupe.senderId,
      // The user has decided: no duplicate check sends it back to review.
      skipDedup: true,
      smsReceivedAt:
          dupe.comparisonTimestampSource == ComparisonTimestampSource.receivedAt
              ? dupe.comparisonTimestamp ?? dupe.occurredAt
              : null,
      capture: CaptureCommit(
        captureId: dupe.id,
        runAtomically: _runAtomically,
        // The capture's own receipt already exists (it points at the
        // original); the kept transaction is found by its id instead.
        writeReceipt: (_) async {},
      ),
    );
    final kept = result.transaction;
    if (kept != null &&
        kept.id == dupe.id &&
        kept.id != dupe.existingTransactionId) {
      await _repository.delete(dupe.id);
    }
    return result;
  }
}
