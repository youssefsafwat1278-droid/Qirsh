import 'dart:convert';
import 'dart:io';

/// Presentation state belongs to the app container, which iOS removes on
/// uninstall. Keychain credentials, privacy barriers and database keys keep
/// their independent security lifetimes.
class InstallPresentationStore {
  InstallPresentationStore(this.file);
  final File file;
  bool requiresSetup = false;
  bool languageChosen = false;

  Future<void> prepare({
    required Future<bool?> Function() hasExistingData,
    required Future<void> Function() resetPresentation,
  }) async {
    var resetPending = false;
    if (await file.exists()) {
      final state = jsonDecode(await file.readAsString());
      if (state is! Map ||
          state['version'] != 1 ||
          state['requiresSetup'] is! bool ||
          state['resetPending'] is! bool) {
        throw StateError('install_presentation_unreadable');
      }
      requiresSetup = state['requiresSetup'] as bool;
      languageChosen = state['languageChosen'] == true || !requiresSetup;
      resetPending = state['resetPending'] as bool;
    } else {
      final existing = await hasExistingData();
      if (existing == null) throw StateError('install_presentation_unknown');
      requiresSetup = !existing;
      languageChosen = existing;
      resetPending = !existing;
      await _write(resetPending: resetPending);
    }
    if (resetPending) {
      // A crash/locked Keychain here retries only this presentation reset.
      await resetPresentation();
      await _write(resetPending: false);
    }
  }

  /// The headless cold-start drain: READ-ONLY. True only for a recorded,
  /// completed setup with no reset pending; anything else (absent, unreadable,
  /// setup or reset outstanding) is the foreground launch's to settle.
  Future<bool> loadCompletedReadOnly() async {
    try {
      if (!await file.exists()) return false;
      final state = jsonDecode(await file.readAsString());
      if (state is! Map ||
          state['version'] != 1 ||
          state['requiresSetup'] != false ||
          state['resetPending'] != false) {
        return false;
      }
      requiresSetup = false;
      languageChosen = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> chooseLanguage() async {
    await _write(resetPending: false, chosenLanguage: true);
    languageChosen = true;
  }

  Future<void> completeSetup() async {
    await _write(resetPending: false, setupRequired: false);
    requiresSetup = false;
  }

  Future<void> _write(
      {required bool resetPending,
      bool? setupRequired,
      bool? chosenLanguage}) async {
    await file.parent.create(recursive: true);
    final contents = jsonEncode({
      'version': 1,
      'requiresSetup': setupRequired ?? requiresSetup,
      'resetPending': resetPending,
      'languageChosen': chosenLanguage ?? languageChosen,
    });
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(contents, flush: true);
    await pending.rename(file.path);
    if (await file.readAsString() != contents) {
      throw StateError('install_presentation_not_persisted');
    }
  }
}
