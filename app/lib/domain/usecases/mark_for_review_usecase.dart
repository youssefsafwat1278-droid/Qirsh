import '../entities/transaction_entity.dart';
import '../repositories/transaction_repository.dart';

/// Owner brief 4.6: "Users must be able to correct a wrongly understood
/// transaction or move it into review." Moves a confirmed transaction back to
/// review (pending, outside totals); [ConfirmTransactionUseCase] restores it.
class MarkForReviewUseCase {
  MarkForReviewUseCase(this._transactionRepository);

  final TransactionRepository _transactionRepository;

  Future<TransactionEntity> call(String transactionId) =>
      _transactionRepository.markForReview(transactionId);
}
