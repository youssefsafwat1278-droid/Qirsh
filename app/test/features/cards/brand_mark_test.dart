import 'dart:async';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
// MALI-071n — merchant-logo consent boundary.
//
// Behavioral: pump BrandMark with cloud-processing consent overridden on/off
// and assert whether an outbound `Image` (network) widget is created at all —
// consent OFF must produce ZERO network image widgets, only bundled/placeholder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/cards/brand_mark.dart';

Future<void> pumpMark(
  WidgetTester tester, {
  required bool allowRemote,
  required String name,
  String? logoUrl,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        remoteMerchantLogosAllowedProvider.overrideWithValue(allowRemote),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: BrandMark(name: name, logoUrl: logoUrl)),
        ),
      ),
    ),
  );
}

void main() {
  test('logo permission stays stable during a settings dependency reload and '
      'still observes a completed revocation', () async {
    final tick = StateProvider<int>((ref) => 0);
    const accepted = UserSettingsEntity(id: 's', country: 'EG', currency: 'EGP',
      language: 'en', theme: 'system', inputMethod: 'manual', notificationsJson: '{}',
      privacyModeEnabled: false, cloudConsentState: ConsentState.accepted);
    final pending = Completer<UserSettingsEntity>();
    final container = ProviderContainer(overrides: [
      userSettingsProvider.overrideWith((ref) {
        return ref.watch(tick) == 0 ? Future.value(accepted) : pending.future;
      }),
    ]);
    addTearDown(container.dispose);
    final subscription = container.listen(remoteMerchantLogosAllowedProvider,
        (_, __) {}, fireImmediately: true);
    addTearDown(subscription.close);
    await container.read(userSettingsProvider.future);
    expect(container.read(remoteMerchantLogosAllowedProvider), isTrue);
    container.read(tick.notifier).state++;
    await Future<void>.delayed(Duration.zero);
    expect(container.read(userSettingsProvider).isReloading, isTrue);
    expect(container.read(remoteMerchantLogosAllowedProvider), isTrue,
        reason: 'routine reload must not replace the displayed logo');
    pending.complete(accepted.copyWith(cloudConsentState: ConsentState.declined));
    await container.read(userSettingsProvider.future);
    expect(container.read(remoteMerchantLogosAllowedProvider), isFalse);
  });

  testWidgets('consent OFF makes ZERO network requests, even with a logoUrl',
      (tester) async {
    // TALABAT has a logo.dev domain AND we pass a catalog logoUrl — both remote.
    await pumpMark(
      tester,
      allowRemote: false,
      name: 'TALABAT',
      logoUrl: 'https://cdn.example.test/talabat.png',
    );
    expect(find.byType(Image), findsNothing); // no Image.network anywhere
    expect(find.byType(Text), findsWidgets); // letter-mark placeholder
  });

  testWidgets('consent ON fetches the catalog logoUrl over the network',
      (tester) async {
    await pumpMark(
      tester,
      allowRemote: true,
      name: 'TALABAT',
      logoUrl: 'https://cdn.example.test/talabat.png',
    );
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('consent ON falls back to logo.dev by public domain',
      (tester) async {
    // No catalog logoUrl → logo.dev path (sends the verified domain, not name).
    await pumpMark(tester, allowRemote: true, name: 'TALABAT');
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('bundled SVG shows offline with consent OFF and makes no request',
      (tester) async {
    await pumpMark(tester, allowRemote: false, name: 'NETFLIX');
    expect(find.byType(SvgPicture), findsOneWidget); // bundled, local
    expect(find.byType(Image), findsNothing); // never a network request
  });

  testWidgets('a remote logo loads over the merchant MONOGRAM, never the '
      'category fallback', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          remoteMerchantLogosAllowedProvider.overrideWithValue(true),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: BrandMark(
                name: 'InstaPay',
                fallback: Icon(Icons.swap_horiz),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('I'), findsOneWidget); // monogram placeholder
    expect(find.byIcon(Icons.swap_horiz), findsNothing);
    expect(find.byType(Image), findsWidgets); // the logo request is in flight
  });
}
