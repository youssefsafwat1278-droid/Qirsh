import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_diagnostics.dart';

/// Errors across all providers are observed without provider names (families
/// can embed account/transaction IDs), values, exceptions or stack messages.
class DiagnosticProviderObserver extends ProviderObserver {
  const DiagnosticProviderObserver();

  @override
  void providerDidFail(ProviderBase<Object?> provider, Object error,
      StackTrace stackTrace, ProviderContainer container) {
    AppDiagnostics.record(AppOperation.provider, AppEventState.failed,
        reason: AppDiagnostics.classify(error),
        area: AppDiagnostics.areaForStack(stackTrace));
  }
}

class DiagnosticNavigationObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      AppDiagnostics.record(AppOperation.navigation, AppEventState.started,
          area: AppDiagnostics.areaForRoute(route.settings.name));
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      AppDiagnostics.record(AppOperation.navigation, AppEventState.succeeded,
          area: AppDiagnostics.areaForRoute(previousRoute?.settings.name));
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      AppDiagnostics.record(AppOperation.navigation, AppEventState.confirmed,
          area: AppDiagnostics.areaForRoute(newRoute?.settings.name));
}

class FlutterDiagnostics with WidgetsBindingObserver {
  FlutterDiagnostics._();
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(FlutterDiagnostics._());
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      AppDiagnostics.record(AppOperation.framework, AppEventState.failed,
          reason: AppDiagnostics.classify(details.exception),
          area: AppDiagnostics.areaForStack(details.stack));
      previousFlutter?.call(details);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      AppDiagnostics.record(AppOperation.framework, AppEventState.failed,
          reason: AppDiagnostics.classify(error),
          area: AppDiagnostics.areaForStack(stack));
      return previousPlatform?.call(error, stack) ?? false;
    };
    AppDiagnostics.record(AppOperation.lifecycle, AppEventState.started);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppDiagnostics.record(
        AppOperation.lifecycle,
        switch (state) {
          AppLifecycleState.resumed => AppEventState.resumed,
          AppLifecycleState.inactive => AppEventState.inactive,
          AppLifecycleState.paused => AppEventState.paused,
          AppLifecycleState.detached => AppEventState.detached,
          AppLifecycleState.hidden => AppEventState.inactive,
        });
    if (state != AppLifecycleState.resumed) unawaited(AppDiagnostics.flush());
  }
}
