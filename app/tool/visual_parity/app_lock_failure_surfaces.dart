// Simulator-only negative persistence transport. No biometric operation or real
// secure-storage read/write occurs. Stored ON is explicitly synthetic view input.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// Use the pinned plugin's public test boundary only in this separate debug tool.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';

final _events = <String, int>{};
Map<String, int> visualParityAppLockFailureEvents() =>
    Map.unmodifiable(_events);
void _event(String key) => _events.update(key, (v) => v + 1, ifAbsent: () => 1);
_LockFailureTransport? _active;
void releaseVisualParityAppLockFailure() => _active?.release();

class _LockFailureTransport extends TestFlutterSecureStoragePlatform {
  _LockFailureTransport() : super({'app_lock_enabled': '1'});
  final gate = Completer<void>();
  void release() {
    if (!gate.isCompleted) gate.complete();
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (key != 'app_lock_enabled' || value != '0') {
      _event('forbidden');
      throw StateError('unexpected_lock_preview_write');
    }
    _event('admitted');
    await gate.future;
    throw PlatformException(code: 'qa_lock_storage_failure');
  }
}

Future<bool> openVisualParityAppLockFailure(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!kDebugMode || SupabaseConfig.isConfigured || _active != null) {
    throw StateError('lock_preview_requires_exclusive_offline_debug');
  }
  final db = ref.read(appDatabaseProvider);
  final attached = await db.customSelect('PRAGMA database_list').get();
  if (!attached.any(
    (r) => r.read<String>('name') == 'main' && r.read<String>('file').isEmpty,
  )) {
    throw StateError('lock_preview_requires_memory');
  }
  if (!context.mounted) return false;
  unawaited(
    Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(builder: (_) => const _Review())),
  );
  return true;
}

class _Review extends StatefulWidget {
  const _Review();
  @override
  State<_Review> createState() => _ReviewState();
}

class _ReviewState extends State<_Review> {
  late final FlutterSecureStoragePlatform previous;
  final transport = _LockFailureTransport();
  @override
  void initState() {
    super.initState();
    previous = FlutterSecureStoragePlatform.instance;
    FlutterSecureStoragePlatform.instance = transport;
    _active = transport;
    _event('opened');
  }

  @override
  void dispose() {
    transport.release();
    if (identical(FlutterSecureStoragePlatform.instance, transport)) {
      FlutterSecureStoragePlatform.instance = previous;
    }
    if (identical(_active, transport)) _active = null;
    _event('closed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SettingsScreen(page: SettingsPage.security);
}
