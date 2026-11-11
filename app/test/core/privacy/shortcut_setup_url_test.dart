import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/gated_url_launcher.dart';
import 'package:money_companion/features/onboarding/shortcut_setup_actions.dart';

void main() {
  test('every link the Bank Texts setup opens passes the shortcut exception', () {
    for (final k in qirshShortcutKeywords) {
      expect(isShortcutSetupUrl(Uri.parse(k.installLink)), isTrue,
          reason: k.term);
      expect(isShortcutSetupUrl(qirshShortcutTestUrl(name: k.runName)), isTrue,
          reason: k.term);
      expect(
          isShortcutSetupUrl(Uri(
              scheme: 'shortcuts',
              host: 'open-shortcut',
              queryParameters: {'name': k.runName})),
          isTrue,
          reason: k.term);
    }
  });

  test('anything else is refused and stays behind the Cloud gate', () {
    for (final url in [
      // Other hosts, look-alikes, other schemes.
      'https://example.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20',
      'https://www.icloud.com.evil.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20',
      'https://icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20',
      'http://www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20',
      'https://user@www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20',
      'https://www.icloud.com:444/shortcuts/55c2b08ad6a94b11b34e328fadf22a20',
      'mailto:a@b.c',
      'tel:123',
      // Other iCloud paths, or data riding on a shortcut link.
      'https://www.icloud.com/photos/',
      'https://www.icloud.com/shortcuts/api/records/55c2b08ad6a94b11b34e328fadf22a20',
      'https://www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20?x=1',
      'https://www.icloud.com/shortcuts/55c2b08ad6a94b11b34e328fadf22a20#frag',
      'https://www.icloud.com/shortcuts/not-an-id',
      // Shortcuts that are not Qirsh's, or that would carry any real text.
      'shortcuts://run-shortcut?name=Upload&input=text&text=QIRSH_SETUP_CHECK_V1',
      'shortcuts://run-shortcut?name=QIRSH&input=text&text=my%20bank%20sms',
      'shortcuts://run-shortcut?name=QIRSH&input=clipboard',
      'shortcuts://run-shortcut?name=QIRSH&input=text&text=QIRSH_SETUP_CHECK_V1&x=1',
      'shortcuts://open-shortcut?name=Other',
      'shortcuts://open-shortcut?name=QIRSH&extra=1',
      'shortcuts://create-shortcut',
      'shortcuts://import-shortcut?url=https://example.com/a.shortcut',
      'shortcuts://x-callback-url/run-shortcut?name=QIRSH',
    ]) {
      expect(isShortcutSetupUrl(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test('a refused link returns false without launching anything', () async {
    expect(
        await launchShortcutSetupUrl(Uri.parse('https://example.com/')), isFalse);
  });
}
