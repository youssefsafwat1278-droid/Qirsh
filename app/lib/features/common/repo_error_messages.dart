import 'package:flutter/widgets.dart';

import '../../core/utils/l10n_ext.dart';
import '../../domain/errors/repo_exceptions.dart';

/// A repository failure in the reader's language.
///
/// `repoExceptionMessage` in the domain layer stays as-is: it has no
/// BuildContext, and background isolates and log lines still need it. This is
/// the UI-side counterpart, used wherever a human is going to read the result.
String repoErrorMessage(BuildContext context, RepoException e) {
  final l = context.l10n;
  return switch (e) {
    NetworkRepoException() => l.repoErrNetwork,
    AuthRepoException() => l.repoErrAuth,
    ValidationRepoException() => l.repoErrValidation,
    ForbiddenRepoException() => l.repoErrForbidden,
    DuplicateRepoException() => l.repoErrDuplicate,
    NotFoundRepoException() => l.repoErrNotFound,
    ServerRepoException() => l.repoErrServer,
    UnknownRepoException() => l.repoErrUnknown,
  };
}
