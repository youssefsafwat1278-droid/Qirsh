import 'package:flutter/widgets.dart';

/// True while a transient overlay route (a bottom sheet or dialog) is on top
/// of the app.
///
/// The bottom nav bar is a native UIKit tab bar (native_glass_navbar) embedded
/// as a platform view. Flutter modal routes are drawn in the Flutter layer and
/// CANNOT occlude a native platform view, so the glass bar bleeds a darker band
/// over any open sheet. The shell watches this and removes the bar from the
/// tree while a sheet/dialog is up, then restores it on dismiss.
final ValueNotifier<bool> modalRouteOpen = ValueNotifier<bool>(false);

class ModalRouteObserver extends NavigatorObserver {
  // Open overlays by identity, not a counter: a route can leave without a
  // matching pop/remove (replaced, or its navigator torn down by the
  // account-scope swap, which notifies no observer). Every event drops any
  // route that is no longer in a live navigator, so the flag cannot stay true
  // without a live sheet/dialog.
  final Set<Route<dynamic>> _open = <Route<dynamic>>{};

  // Bottom sheets and dialogs are PopupRoutes; full-page navigations
  // (MaterialPageRoute) are not — those swap the whole screen and must not
  // toggle the bar.
  bool _isOverlay(Route<dynamic>? route) => route is PopupRoute;

  void _update({Route<dynamic>? added, Route<dynamic>? removed}) {
    _open.remove(removed);
    if (_isOverlay(added)) _open.add(added!);
    _open.removeWhere((route) => !route.isActive);
    final open = _open.isNotEmpty;
    if (modalRouteOpen.value != open) modalRouteOpen.value = open;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(added: route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(removed: route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(removed: route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _update(added: newRoute, removed: oldRoute);
}

final ModalRouteObserver modalRouteObserver = ModalRouteObserver();
