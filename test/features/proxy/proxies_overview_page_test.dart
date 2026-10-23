import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_page.dart';
import 'package:hiddify/hiddifycore/generated/google/protobuf/timestamp.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The core's side, narrowed to what the page reads.
class _Repository implements ProxyRepository {
  final updates = StreamController<Either<ProxyFailure, OutboundGroup?>>.broadcast();

  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => updates.stream;

  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) => TaskEither.right(unit);

  @override
  TaskEither<ProxyFailure, Unit> urlTest(String groupTag) => TaskEither.right(unit);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Notifications extends InAppNotificationController {
  @override
  void showErrorToast(String message) {}
}

OutboundInfo _proxy(String tag, int delay) => OutboundInfo(
  tag: tag,
  tagDisplay: tag,
  urlTestDelay: delay,
  urlTestTime: Timestamp.fromDateTime(DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true)),
);

/// Renders the page at [size] logical pixels with a fake core behind it.
/// Returns the container so the test can push events into the stream.
Future<ProviderContainer> pumpPage(WidgetTester tester, Size size, {bool serviceRunning = true}) async {
  SharedPreferences.setMockInitialValues({'haptic_feedback': false});
  final repository = _Repository();
  final container = ProviderContainer(
    overrides: [
      serviceRunningProvider.overrideWithValue(serviceRunning),
      proxyRepositoryProvider.overrideWithValue(repository),
      inAppNotificationControllerProvider.overrideWithValue(_Notifications()),
      translationsProvider.overrideWith((ref) => AppLocale.en.build()),
    ],
  );
  addTearDown(container.dispose);
  await tester.runAsync(() => container.read(sharedPreferencesProvider.future));
  await tester.runAsync(() => container.read(translationsProvider.future));

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ProxiesOverviewPage()),
    ),
  );
  container.listen(proxiesOverviewNotifierProvider, (_, _) {});
  return container;
}

void main() {
  testWidgets('a streamed group renders its rows and scales the columns with the width', (tester) async {
    final container = await pumpPage(tester, const Size(1200, 800));
    final repository = container.read(proxyRepositoryProvider) as _Repository;
    repository.updates.add(
      right(OutboundGroup(tag: 'select', selected: 'a', items: [_proxy('a', 100), _proxy('b', 200), _proxy('c', 0)])),
    );
    // The notifier merges events within 300ms, so the pump has to cross it.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.byType(ListTile), findsNWidgets(3));
    // The delay is the tile's trailing label; the untested proxy shows none.
    expect(find.text('100'), findsOneWidget);
    expect(find.text('200'), findsOneWidget);

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    // 1200 minus the two 16px gutters leaves 1168, which fits 4 columns of 268.
    expect(delegate.crossAxisCount, 4);
  });

  testWidgets('a narrow window falls back to a single column', (tester) async {
    final container = await pumpPage(tester, const Size(400, 800));
    final repository = container.read(proxyRepositoryProvider) as _Repository;
    repository.updates.add(
      right(OutboundGroup(tag: 'select', selected: 'a', items: [_proxy('a', 100), _proxy('b', 200)])),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 1);
  });

  testWidgets('a core that is not running offers a retry instead of a dead end', (tester) async {
    // The notifier turns a stopped service into an error state; a failed list
    // event is different and keeps the last rows on screen by design.
    await pumpPage(tester, const Size(1200, 800), serviceRunning: false);
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });
}
