import 'package:flutter/foundation.dart' show kReleaseMode;

import '../../features/capture/services/native_capture_bridge.dart';
import '../backend/supabase_config.dart';
import '../observability/diagnostics.dart';
import '../session/app_session.dart';

/// QA ONLY, never in a release build and never with a configured backend:
/// `--dart-define=QIRSH_QA_LOCAL_UID=<synthetic id>` signs a synthetic LOCAL
/// identity in through the real [AppSession] path (admission, replica, keys)
/// and turns on SMS auto-capture, so the cold-start background capture drain
/// can be demonstrated on an emulator with synthetic SMS and no sign-in to any
/// backend. `kReleaseMode` is a compile-time constant: the body is removed
/// from release builds.
Future<void> debugQaLocalIdentity() async {
  if (kReleaseMode) return;
  const uid = String.fromEnvironment('QIRSH_QA_LOCAL_UID');
  if (uid.isEmpty || SupabaseConfig.isConfigured) return;
  final session = AppSession.instance;
  if (session.status != SessionStatus.authenticated) {
    await session.completeOnboarding(
        method: 'google', email: '$uid@example.invalid', userId: uid);
  }
  final enabled = await NativeCaptureBridge.setAutomaticSmsCaptureEnabled(true);
  Diag.log('[CaptureBg]',
      'qa_identity status=${session.status.name} autoCapture=$enabled');
}
