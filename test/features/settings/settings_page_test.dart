import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/settings/overview/settings_page.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The page resolves every row through `context.namedLocation`, so the router
/// needs the names it asks for.
GoRouter _router() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => SettingsPage()),
    for (final name in [
      'general',
      'chainOptions',
      'routingOptions',
      'dnsOptions',
      'inboundOptions',
      'tlsTricks',
      'logs',
      'about',
    ])
      GoRoute(path: '/$name', name: name, builder: (_, _) => const SizedBox()),
  ],
);

Future<void> pumpSettings(WidgetTester tester, double width, {bool hasProfiles = false}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      hasAnyProfileProvider.overrideWith((ref) => Stream.value(hasProfiles)),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(() => container.read(translationsProvider.future));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: _router()),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a wide window keeps the list at one readable width', (tester) async {
    await pumpSettings(tester, 1200);
    expect(tester.getSize(find.byType(ListView)).width, 720);
  });

  testWidgets('a narrow window lets the list use the whole width', (tester) async {
    await pumpSettings(tester, 500);
    expect(tester.getSize(find.byType(ListView)).width, 500);
  });

  testWidgets('the chain row only shows when a profile exists', (tester) async {
    await pumpSettings(tester, 1200);
    expect(find.byType(SettingsSection), findsNWidgets(5));

    await pumpSettings(tester, 1200, hasProfiles: true);
    expect(find.byType(SettingsSection), findsNWidgets(6));
  });
}
