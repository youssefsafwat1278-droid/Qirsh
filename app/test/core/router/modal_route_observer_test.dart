import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/router/modal_route_observer.dart';

/// RT-01: `modalRouteOpen` hides the native tab bar while a sheet/dialog is up.
/// It must return to false on every way a sheet can leave the navigator —
/// including the navigator itself being torn down with the sheet still open
/// (the account-scope swap on sign-in/sign-out remounts the whole app under a
/// new `ProviderScope` key, and a disposed navigator notifies no observer).
void main() {
  setUp(() => modalRouteOpen.value = false);
  tearDown(() => modalRouteOpen.value = false);

  GoRouter router(ModalRouteObserver observer) => GoRouter(
        initialLocation: '/a',
        observers: [observer],
        routes: [
          GoRoute(path: '/a', builder: (_, __) => const Text('page a')),
          GoRoute(path: '/b', builder: (_, __) => const Text('page b')),
        ],
      );

  Future<BuildContext> pumpRouter(WidgetTester tester, GoRouter r) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: r));
    return tester.element(find.text('page a'));
  }

  void openSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context, builder: (_) => const Text('sheet'));

  void openDialog(BuildContext context) => showDialog<void>(
      context: context, builder: (_) => const Text('dialog'));

  testWidgets('push then pop', (tester) async {
    final r = router(ModalRouteObserver());
    final context = await pumpRouter(tester, r);
    openSheet(context);
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isTrue);
    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse);
  });

  testWidgets('push then removeRoute', (tester) async {
    final r = router(ModalRouteObserver());
    final context = await pumpRouter(tester, r);
    openSheet(context);
    await tester.pumpAndSettle();
    final sheetRoute = ModalRoute.of(tester.element(find.text('sheet')))!;
    Navigator.of(context).removeRoute(sheetRoute);
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse);
  });

  testWidgets('push then replace with a page and with another sheet',
      (tester) async {
    final r = router(ModalRouteObserver());
    final context = await pumpRouter(tester, r);
    openSheet(context);
    await tester.pumpAndSettle();
    final navigator = Navigator.of(context);
    final sheetRoute = ModalRoute.of(tester.element(find.text('sheet')))!;
    final dialog = DialogRoute<void>(
        context: context, builder: (_) => const Text('dialog'));
    navigator.replace(oldRoute: sheetRoute, newRoute: dialog);
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isTrue);
    navigator.replace(
        oldRoute: dialog,
        newRoute: MaterialPageRoute<void>(builder: (_) => const Text('page')));
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse);
  });

  testWidgets('nested modals stay open until the last one closes',
      (tester) async {
    final r = router(ModalRouteObserver());
    final context = await pumpRouter(tester, r);
    openSheet(context);
    await tester.pumpAndSettle();
    openDialog(tester.element(find.text('sheet')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('dialog'))).pop();
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isTrue);
    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse);
  });

  testWidgets('router go() replaces the stack while a sheet is open',
      (tester) async {
    final r = router(ModalRouteObserver());
    final context = await pumpRouter(tester, r);
    openSheet(context);
    await tester.pumpAndSettle();
    r.go('/b');
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
    expect(modalRouteOpen.value, isFalse);
  });

  testWidgets(
      'navigator torn down with a sheet open (account-scope swap) '
      'does not leave the flag stuck', (tester) async {
    // Mirrors main.dart: the app (and the router's navigator) is unmounted
    // while the scope is withdrawn, then remounted under a new key. The same
    // global router and observer are reused, as in the app.
    final observer = ModalRouteObserver();
    final r = router(observer);
    final generation = ValueNotifier<int?>(1);
    addTearDown(generation.dispose);
    await tester.pumpWidget(ValueListenableBuilder<int?>(
      valueListenable: generation,
      builder: (_, g, __) => g == null
          ? const SizedBox.shrink()
          : KeyedSubtree(
              key: ValueKey(g), child: MaterialApp.router(routerConfig: r)),
    ));
    openSheet(tester.element(find.text('page a')));
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isTrue);

    generation.value = null; // scope withdrawn: navigator disposed
    await tester.pumpAndSettle();
    generation.value = 2; // next scope published: new navigator
    await tester.pumpAndSettle();

    expect(find.text('sheet'), findsNothing);
    expect(modalRouteOpen.value, isFalse);

    // And the observer keeps working on the new navigator.
    openSheet(tester.element(find.text('page a')));
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isTrue);
    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse);
  });
}
