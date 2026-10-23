import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/app_info_entity.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/theme/app_layout.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/home_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class _FakeAppInfo extends AppInfo {
  @override
  Future<AppInfoEntity> build() => Future.value(
    const AppInfoEntity(
      name: 'hiddify',
      version: '5.0.1',
      buildNumber: '50001',
      release: Release.general,
      operatingSystem: 'windows',
      operatingSystemVersion: 'test',
      environment: Environment.prod,
    ),
  );
}

class _FakeActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

class _FakeConnection extends ConnectionNotifier {
  _FakeConnection(this.status);

  final ConnectionStatus status;

  @override
  Stream<ConnectionStatus> build() => Stream.value(status);
}

class _FakeActiveProxy extends ActiveProxyNotifier {
  @override
  Stream<OutboundInfo> build() => Stream.value(OutboundInfo());
}

/// Renders the page at [width]x[height] logical pixels (device pixel ratio 1).
Future<void> pumpHome(WidgetTester tester, double width, {double height = 800, ConnectionStatus status = const Disconnected()}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      appInfoProvider.overrideWith(() => _FakeAppInfo()),
      activeProfileProvider.overrideWith(() => _FakeActiveProfile()),
      hasAnyProfileProvider.overrideWith((ref) => Stream.value(false)),
      connectionNotifierProvider.overrideWith(() => _FakeConnection(status)),
      activeProxyNotifierProvider.overrideWith(() => _FakeActiveProxy()),
      hotReloadingProvider.overrideWith((ref) => Stream.value(false)),
    ],
  );
  addTearDown(container.dispose);

  // The page calls requireValue on the translations, so they have to be ready
  // before the first frame. MaterialApp provides the Directionality and
  // MediaQuery the Scaffold expects.
  await tester.runAsync(() => container.read(translationsProvider.future));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomePage()),
    ),
  );
  // A second pump lets the async fakes land; pumpAndSettle never settles here
  // because the delay indicator's skeleton animates forever.
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

final _sideColumn = find.byWidgetPredicate((widget) => widget is SizedBox && widget.width == AppLayout.sideColumnWidth);
final _connectionButton = find.byKey(const ValueKey('home_connection_button'));

/// Diameter the connection button settled on.
double _buttonSize(WidgetTester tester) =>
    tester.widget<SizedBox>(find.byKey(const ValueKey('home_connection_button_size'))).width!;
final _narrowConstraints = find.byWidgetPredicate(
  (widget) => widget is ConstrainedBox && widget.constraints.maxWidth == AppLayout.maxColumnWidth,
);
final _wideConstraints = find.byWidgetPredicate(
  (widget) => widget is ConstrainedBox && widget.constraints.maxWidth == 520,
);

void main() {
  testWidgets('a wide window lays the page out in two columns', (tester) async {
    await pumpHome(tester, 1200);
    expect(_sideColumn, findsOneWidget);
    expect(_wideConstraints, findsOneWidget);
    expect(_narrowConstraints, findsNothing);
    expect(_connectionButton, findsOneWidget);
    // Desktop widths show the version chip next to the title.
    expect(find.text('5.0.1'), findsOneWidget);
  });

  testWidgets('a narrow window stays a single scrolling column', (tester) async {
    await pumpHome(tester, 500);
    expect(_sideColumn, findsNothing);
    expect(_wideConstraints, findsNothing);
    expect(_narrowConstraints, findsOneWidget);
    expect(_connectionButton, findsOneWidget);
    // Phone widths hide the version chip; the about page carries it.
    expect(find.text('5.0.1'), findsNothing);
  });

  testWidgets('the connection button takes the size it was designed for when there is room', (tester) async {
    await pumpHome(tester, 1200);
    expect(_buttonSize(tester), AppLayout.maxButtonSize);
  });

  testWidgets('the connection button shrinks on a short window instead of overflowing', (tester) async {
    await pumpHome(tester, 500);
    final roomy = _buttonSize(tester);

    await pumpHome(tester, 500, height: 420);
    final short = _buttonSize(tester);

    expect(short, lessThan(roomy));
    // A short window still has to keep the ring big enough to read as a button.
    expect(short, greaterThanOrEqualTo(AppLayout.minButtonSize - 1));
    // Overflow would have thrown while laying the page out.
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short window keeps the button above the proxy card', (tester) async {
    // Connected: the proxy card under the button is part of the column too, and
    // the button has to leave room for it instead of overflowing the page.
    await pumpHome(tester, 500, height: 420, status: const Connected());
    expect(_buttonSize(tester), AppLayout.minButtonSize);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rail threshold width shows two columns before the rail expands', (tester) async {
    // 1000 < 1100: the rail is icon-only (72px) yet the page already has two
    // columns, which is the whole point of the 880 content threshold.
    await pumpHome(tester, 1000);
    expect(_sideColumn, findsOneWidget);
    expect(_wideConstraints, findsOneWidget);
  });
}
