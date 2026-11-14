import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Consent-security amendment (Dart session / transaction unit): static pins on
/// the source properties the behavioural tests (consent_capability_session_test,
/// consent_typed_write_test, enable_cloud_lifetime_test) rely on, so a regression
/// fails in CI even where a fixture is not run. SUPPLEMENTARY source pins, not
/// behaviour proof.

/// The brace-matched body of the member that starts at [signature]. Parsing
/// problems are descriptive [StateError]s, never `expect`: this runs from
/// `setUpAll` (a valid test zone) and from test bodies only.
String _body(String source, String signature) {
  final at = source.indexOf(signature);
  if (at < 0) throw StateError('$signature not found');
  var from = at + signature.length;
  if (signature.endsWith('(')) {
    // Skip the parameter list (its named-parameter braces are not the body).
    var parens = 1;
    while (from < source.length && parens > 0) {
      if (source[from] == '(') parens++;
      if (source[from] == ')') parens--;
      from++;
    }
    if (parens != 0) throw StateError('unbalanced parentheses after $signature');
  }
  final open = source.indexOf('{', from);
  if (open < 0) throw StateError('no body after $signature');
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(open, i + 1);
    }
  }
  throw StateError('unbalanced braces after $signature');
}

// Missing source anchors must fail before any ordering comparison: -1 can
// otherwise accidentally satisfy a less-than assertion.
int _anchor(String source, String text) {
  final at = source.indexOf(text);
  if (at < 0) throw StateError('source anchor not found: $text');
  return at;
}

void main() {
  late String session;
  late String service;
  late String repository;
  late String privacy;
  late String sheet;
  late String capture;
  late String issue;
  late String signOut;
  late String invalid;
  late String resolve;
  late String enablePublic;
  late String withdraw;
  late String turnOff;
  late String turnOn;
  late String applyChoice;
  late String grant;
  late String saveTx;

  setUpAll(() {
    session = File('lib/core/session/app_session.dart').readAsStringSync();
    service = File(
            'lib/features/capture/services/capture_device_registration_service.dart')
        .readAsStringSync();
    repository =
        File('lib/data/repositories/drift_user_settings_repository.dart')
            .readAsStringSync();
    privacy = File('lib/features/settings/privacy_screen.dart')
        .readAsStringSync();
    sheet = File('lib/features/consent/smart_analysis_consent_sheet.dart')
        .readAsStringSync();
    capture = _body(session, 'ConsentCapability? captureConsentCapability(');
    issue = _body(session, 'void _issueConsentCapability(');
    signOut = _body(session, 'Future<SignOutOutcome> signOut(');
    invalid = _body(session, 'void markSessionInvalid(');
    resolve = _body(session,
        'Future<LocalDataOwnership> _resolveLocalDataOwnership(\n    String uid,\n    _Admission adm,\n  ) async');
    final at = service.indexOf('Future<void> enableCloud(');
    if (at < 0) throw StateError('enableCloud not found');
    // An arrow member: its whole declaration up to the semicolon.
    enablePublic = service.substring(at, service.indexOf(';', at));
    withdraw = _body(privacy, 'Future<void> _withdrawConsent(');
    turnOff = _body(privacy, 'Future<void> _turnOff()');
    turnOn = _body(privacy, 'Future<void> _turnOn()');
    applyChoice =
        _body(sheet, 'Future<UserSettingsEntity> applyConsentChoice(');
    grant = _body(sheet, 'Future<void> _grant(');
    saveTx = _body(repository, 'Future<UserSettingsEntity> _saveWithinTransaction(');
  });

  test('both foreground service owners provide a durable settings queue', () {
    final providers = File('lib/core/di/app_providers.dart').readAsStringSync();
    final bootstrap = File('lib/core/startup/bootstrap_runner.dart').readAsStringSync();
    expect(providers, contains('''final service = CaptureDeviceRegistrationService(
    settingsRepository: DriftUserSettingsRepository(
      database,
      outboxQueue: ref.watch(planningOutboxQueueProvider),'''));
    expect(bootstrap, contains('''final captureRegistration = CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(
          database,
          outboxQueue: buildPlanningOutboxQueue(database),'''));
  });

  test('no capability is derived from status, local-work authority or the '
      'active database', () {
    expect(capture, isNot(contains('captureLocalWorkAuthority')));
    expect(capture, isNot(contains('SessionStatus.authenticated')));
    expect(capture, isNot(contains('activeScope')));
    expect(capture, isNot(contains('ConsentCapability(')),
        reason: 'it only returns what a committed publication issued');
  });

  test('issuance needs the actual SDK evidence and never a predicate alone',
      () {
    expect(session, contains('required bool Function() sdkFresh,'));
    expect(issue, contains('!sdkFresh()'));
    expect(issue, contains("method == 'guest'"));
    expect(session, contains('bool _sdkSessionFresh(String uid'));
    // both publications that may issue pass real SDK evidence
    expect(session,
        contains('sdkFresh: () => _sdkSessionFresh(uid),'));
    expect(session,
        contains('sdkFresh: () => _sdkSessionFresh(uid, client),'));
  });

  test('revocation is dropped synchronously at the real loss origins', () {
    expect(_anchor(invalid, '_revokeConsentProof();'),
        lessThan(_anchor(invalid, 'if (isGuest')),
        reason: 'before any early return');
    expect(session, contains('_authLossSeq++;\n          _revokeConsentProof();'));
    expect(session,
        contains('_revokeConsentProof(expiry: true); '
            '// an expired SDK session proves nothing'));
    expect(session,
        contains('_revokeConsentProof(); // no SDK session: the proof ends here'));
    // the helper drops the proof AND advances the dedicated loss generation
    expect(_body(session, 'void _revokeConsentProof('),
        allOf(contains('_consentCapability = null;'),
            contains('_consentLossSeq++;')));
  });

  test('both admissions capture the loss generation before their first await '
      'and issue only against it', () {
    final publicIdentity = _body(session, 'Future<void> setIdentity(');
    expect(publicIdentity, contains('final probe = _ReconnectProbe();'));
    expect(publicIdentity, contains('probe: probe,'));
    expect(_anchor(publicIdentity, 'await _setIdentity('),
        lessThan(_anchor(publicIdentity, 'catch (_)')));
    expect(publicIdentity,
        contains('if (probe.began) _scheduleFreshLocalReadRestore(probe);'));
    expect(_anchor(publicIdentity, '_scheduleFreshLocalReadRestore(probe);'),
        lessThan(_anchor(publicIdentity, 'rethrow;')));
    final setIdentity = _body(session, 'Future<void> _setIdentity(');
    expect(_anchor(setIdentity, 'final consentLossAtAcceptance = _consentLossSeq;'),
        lessThan(_anchor(setIdentity, 'await ')));
    expect(setIdentity, contains('consentLossSeq: consentLossAtAcceptance'));
    final reconcile = _body(session, 'Future<bool?> _reconcileSupabaseSession(');
    expect(_anchor(reconcile, 'final consentLossSeq = _consentLossSeq;'),
        lessThan(_anchor(reconcile, 'await _ensureLocalDataOwnedBy')));
    expect(reconcile, contains('consentLossSeq: consentLossSeq'));
    expect(issue, contains('_consentLossSeq != consentLossSeq'));
    expect(issue, contains('status == SessionStatus.sessionExpired'));
  });

  test('logout: closed synchronously, failure latched, counter released', () {
    final firstAwait = _anchor(signOut, 'await drainAdmissions();');
    expect(_anchor(signOut, '_logoutsAccepted++;'), lessThan(firstAwait));
    expect(_anchor(signOut, '_admissionEpoch++;'), lessThan(firstAwait));
    expect(signOut, contains('await drainAdmissions();'));
    expect(signOut, contains('_logoutIncomplete = true;'));
    expect(signOut, contains('_logoutsAccepted--;'));
    expect(signOut, contains('completed = true;'));
    // a failed logout never leaves the old authority usable
    expect(session, contains('_logoutIncomplete ||'));
    expect(session, contains('if (!adm.explicit && _logoutIncomplete)'));
  });

  test('the automatic switch latch is reopened only by the actual publication',
      () {
    expect(resolve, isNot(contains('_accountSwitchEpoch = null')),
        reason: 'not at the ownership result');
    expect(session,
        contains('_accountSwitchEpoch == adm.authority.epoch) {\n          _accountSwitchEpoch = null;'));
  });

  test('the public enable has no arbitrary save callback', () {
    expect(service, contains('Future<void> enableCloud({required ConsentWrite write})'));
    expect(enablePublic, isNot(contains('commitLocalOn')));
    expect(enablePublic, contains('required ConsentWrite write'));
    expect(service, contains('@visibleForTesting\n  Future<void> enableCloudForTest('));
    // no production caller of the test-only entry
    for (final f in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('capture_device_registration_service.dart')) continue;
      final text = f.readAsStringSync();
      expect(text, isNot(contains('enableCloudForTest')), reason: f.path);
      expect(text, isNot(contains('commitLocalOn')), reason: f.path);
    }
  });

  test('both production consent entries use the typed capability and writer',
      () {
    // WITHDRAWAL (the Privacy screen): the typed write under the capability the
    // confirmation was bound to; the restrictive disable for Cloud ON -> OFF.
    expect(withdraw, isNot(contains('saveSettings(')));
    expect(withdraw, isNot(contains('commitLocalOn')));
    expect(withdraw, contains('saveConsentChoice(work.capability, choices)'));
    expect(withdraw, contains('choices.applyTo(before)'));
    expect(withdraw, contains('registration.isDisablingCloud(before, updated)'));
    expect(withdraw, contains('registration.disableCloud('));
    expect(withdraw, contains('cloud: ConsentState.declined'));
    expect(withdraw, contains('ai: ConsentState.declined'));
    // merchant personalization is a separate local operation, never a consent
    expect(withdraw, isNot(contains('merchantPersonalization')));
    expect(_body(privacy, 'Future<void> _setMerchantPersonalization('),
        isNot(anyOf(contains('registration'), contains('enableCloud'),
            contains('disableCloud'), contains('syncBackendState'))));
    // ENABLE (the disclosure -> typed service): the only widening path.
    expect(applyChoice, contains('ConsentWrite(scope.capability, choices)'));
    expect(applyChoice, contains('choices.applyTo(current)'));
    expect(sheet, isNot(contains('saveSettings(')));
  });

  test('the Privacy screen has no enable branch: it can only withdraw', () {
    expect(privacy, isNot(contains('enableCloud(')));
    expect(privacy, isNot(contains('isEnablingCloud')));
    expect(privacy, isNot(contains('ConsentWrite(')));
    expect(privacy, isNot(contains('_setConsent')));
    expect(withdraw, isNot(contains('enableCloud')));
    expect(RegExp(r'ConsentState\.accepted').hasMatch(privacy), isFalse);
  });

  test('management Turn on reaches the durable enable only through the '
      'disclosure and the typed service route', () {
    // Privacy screen -> disclosure, bound to the capability captured first.
    expect(turnOn, contains('showSmartAnalysisConsentSheet(context, ref,'));
    expect(turnOn, contains('management: true'));
    expect(turnOn, contains('work: work'));
    expect(_anchor(turnOn, 'consentLocalWorkProvider'),
        lessThan(_anchor(turnOn, 'showSmartAnalysisConsentSheet(')));
    // Accept -> the typed save -> the route chosen from stored AND live state.
    expect(grant, contains('saveConsentChoice(ref,'));
    expect(grant, contains('work: work'));
    final saveAt = _anchor(grant, 'saveConsentChoice(ref,');
    expect(_anchor(grant, 'service.retry()'), greaterThan(saveAt),
        reason: 'registration only after the save/enable returned');
    expect(_anchor(grant, 'service.syncBackendState()'), greaterThan(saveAt));
    expect(_anchor(applyChoice, 'service.explicitEnableRoute('),
        lessThan(_anchor(applyChoice, 'service.enableCloud(')));
    expect(applyChoice, contains('ExplicitEnableRoute.withdrawFirst'));
    expect(applyChoice,
        contains('throw const CloudEnableWithdrawFirstException()'));
    // A plain save is a branch of the route, never the default.
    expect(applyChoice, contains('case ExplicitEnableRoute.plainSave:'));
    // The service-side chain: the route and the native enable.
    expect(service, contains('Future<ExplicitEnableRoute> explicitEnableRoute('));
    expect(service, contains('Future<void> _enableCloudNative('));
  });

  test('the withdrawal scope is bound before the confirmation and verified '
      'after it', () {
    final capture = _anchor(turnOff, 'consentLocalWorkProvider');
    final dialog = _anchor(turnOff, 'showDialog<bool>(');
    expect(capture, isNonNegative);
    expect(capture, lessThan(dialog), reason: 'scope captured BEFORE the dialog');
    final after = turnOff.substring(dialog);
    expect(after, isNot(contains('consentLocalWorkProvider')),
        reason: 'never re-captured after the confirmation');
    expect(after, contains('!scope.current'));
    expect(after, contains('widget.withdraw(\n        ref,\n        scope,'));
  });

  test('the typed transaction revalidates after every async boundary and '
      'before each mutation', () {
    expect(
        _anchor(saveTx, 'await getSettings();'),
        lessThan(_anchor(saveTx, 'checkpoint?.call();')),
        reason: 'revalidated right after the awaited read');
    expect(_anchor(saveTx, 'checkpoint?.call();'),
        lessThan(_anchor(saveTx, 'UPDATE user_settings')),
        reason: 'before the first mutation');
    expect(RegExp(r'checkpoint\?\.call\(\)').allMatches(saveTx).length, 3);
    final typed = _body(repository, 'Future<UserSettingsEntity> _saveConsentChoice(');
    expect(typed, contains('SELECT owner_uid FROM replica_meta'));
    expect(typed, contains('identical(capability.database, _db)'));
    _anchor(typed, 'capability.requireCurrent();');
    expect(typed.lastIndexOf('capability.requireCurrent();'),
        greaterThan(_anchor(typed, '_saveWithinTransaction(')),
        reason: 'the final synchronous guard follows the last awaited work');
  });
}
