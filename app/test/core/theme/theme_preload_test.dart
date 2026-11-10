import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/theme_mode_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('saved appearance is synchronous for a new provider graph', () async {
    FlutterSecureStorage.setMockInitialValues({'app_theme_mode': 'dark'});
    await ThemeModeController.preload();
    final first = ThemeModeController();
    expect(first.state, ThemeMode.dark);
    first.dispose();
    final resumed = ThemeModeController();
    expect(resumed.state, ThemeMode.dark);
    await resumed.set(ThemeMode.light);
    resumed.dispose();
    final afterChoice = ThemeModeController();
    expect(afterChoice.state, ThemeMode.light);
    afterChoice.dispose();
  });
}
