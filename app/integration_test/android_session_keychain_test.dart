import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/auth/session_keychain.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:path_provider/path_provider.dart';

/// ANDROID SESSION KEYCHAIN — the real `qirsh/session_keychain` handler
/// (`SessionKeychain.kt`) against the device's real Android Keystore, file
/// system and `flutter_secure_storage` EncryptedSharedPreferences.
///
/// Before this handler existed every call failed, so the session store
/// deferred forever and a configured Android build never left the loading
/// screen. Synthetic values only; every probe item is removed afterwards.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final keychain = MethodChannelSessionKeychain();
  final probe = 'qirsh.it.session_probe.${DateTime.now().microsecondsSinceEpoch}';
  const pluginProbe = 'qirsh_it_plugin_probe';
  const tokenA = 'synthetic-refresh-token-A-0123456789';
  const tokenB = 'synthetic-refresh-token-B-9876543210';

  tearDown(() async {
    await keychain.delete(probe);
    await SecureStorageOptions.storage.delete(key: pluginProbe);
  });

  testWidgets('protected data is reported available once the app runs',
      (tester) async {
    expect(await keychain.protectedDataAvailable(), isTrue);
  }, skip: !Platform.isAndroid);

  testWidgets('owned item: absent → write → found → overwrite → delete → absent',
      (tester) async {
    expect((await keychain.read(probe)).status, KeychainStatus.absent);
    expect((await keychain.write(probe, '{"t":"$tokenA"}')).status,
        KeychainStatus.ok);
    final a = await keychain.read(probe);
    expect(a.status, KeychainStatus.found);
    expect(a.value, '{"t":"$tokenA"}');
    expect((await keychain.write(probe, '{"t":"$tokenB"}')).status,
        KeychainStatus.ok);
    expect((await keychain.read(probe)).value, '{"t":"$tokenB"}');
    expect((await keychain.delete(probe)).status, KeychainStatus.ok);
    expect((await keychain.read(probe)).status, KeychainStatus.absent);
    expect((await keychain.delete(probe)).status, KeychainStatus.ok);
  }, skip: !Platform.isAndroid);

  testWidgets('sealed at rest in no_backup, never plaintext', (tester) async {
    await keychain.write(probe, '{"t":"$tokenA"}');
    final files = await getApplicationSupportDirectory(); // <data>/files
    final store =
        File('${files.parent.path}/no_backup/qirsh_session_keychain_v1.store');
    expect(store.existsSync(), isTrue);
    final raw = store.readAsStringSync();
    expect(raw.startsWith('qsk-store-v1\n'), isTrue);
    expect(raw.contains(tokenA), isFalse);
    expect(raw.contains('"t"'), isFalse);
    expect(raw.contains(probe), isFalse, reason: 'item names are hex-encoded');
  }, skip: !Platform.isAndroid);

  testWidgets('readPluginItem keeps the status of flutter_secure_storage items',
      (tester) async {
    expect((await keychain.readPluginItem(pluginProbe)).status,
        KeychainStatus.absent);
    await SecureStorageOptions.storage.write(key: pluginProbe, value: 'v1');
    final r = await keychain.readPluginItem(pluginProbe);
    expect(r.status, KeychainStatus.found);
    expect(r.value, 'v1');
    await SecureStorageOptions.storage.delete(key: pluginProbe);
    expect((await keychain.readPluginItem(pluginProbe)).status,
        KeychainStatus.absent);
  }, skip: !Platform.isAndroid);
}
