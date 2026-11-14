import 'package:flutter/services.dart';

import 'app_diagnostics.dart';

/// Explicit user action, available in release as well as development builds.
/// Copies only the closed-vocabulary local journal. It never uploads anything
/// or exposes the developer-only database/capability diagnostics surface.
Future<void> copyAppDiagnostics() async {
  await AppDiagnostics.refreshBackground()
      .timeout(const Duration(seconds: 1), onTimeout: () {});
  await Clipboard.setData(ClipboardData(text: AppDiagnostics.exportText()));
}
