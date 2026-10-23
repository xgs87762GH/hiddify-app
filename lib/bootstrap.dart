import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hiddify/core/analytics/analytics_controller.dart';
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/logger/logger.dart';
import 'package:hiddify/core/logger/logger_setup.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/app/widget/app.dart';
import 'package:hiddify/features/auto_start/notifier/auto_start_notifier.dart';
import 'package:hiddify/features/chain/model/chain_enum.dart';
import 'package:hiddify/features/chain/notifier/chain_profile_notifier.dart';

import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/system_tray/notifier/system_tray_notifier.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/riverpod_observer.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

Future<void> lazyBootstrap(WidgetsBinding widgetsBinding, Environment env) async {
  if (!kIsWeb) {
    FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  }
  if (PlatformUtils.isDesktop) {
    // The runner shows the window the moment the engine starts and the app
    // paints nothing on it until it renders its first frame. The boot below
    // takes seconds, so the window goes away right now and comes back once
    // there is something to show: an empty grey rectangle reads as a broken
    // app, and the user waits on it.
    await hideWindowUntilReady();
  }
  // phase 1 — console and the in-memory history, before the folders are known
  logStart();
  FlutterError.onError = Logger.logFlutterError;
  WidgetsBinding.instance.platformDispatcher.onError = Logger.logPlatformDispatcherError;

  final stopWatch = Stopwatch()..start();

  final container = ProviderContainer(
    overrides: [environmentProvider.overrideWithValue(env)],
    observers: [RiverpodObserver()],
  );

  await _init("directories", () => container.read(appDirectoriesProvider.future));
  // phase 2 — the folders exist, so app.log can be opened
  logAddFile(container.read(logPathResolverProvider).appFile().path);
  // The engine appends to its own log for the life of the install and never
  // rotates it. It is not running yet, which is the only time it can be cut.
  container.read(logPathResolverProvider).trimCoreLog();

  // App info and preferences read different stores and nothing below uses one
  // before both are done, so they run side by side. Translations are not in
  // this group: the locale they build comes out of the preferences.
  final (appInfo, _) = await (
    _init("app info", () => container.read(appInfoProvider.future)),
    _init("preferences", () => container.read(sharedPreferencesProvider.future)),
  ).wait;
  await _init("translations", () => container.read(translationsProvider.future));
  // The ring starts at a safe default and only now learns the size the user
  // picked, since nothing could be read from disk before this point.
  logRing.capacity = container.read(Preferences.logBufferSize);

  final enableAnalytics = await container.read(analyticsControllerProvider.future);
  if (enableAnalytics) {
    await _init("analytics", () => container.read(analyticsControllerProvider.notifier).enableAnalytics());
  }

  await _init("preferences migration", () async {
    try {
      await PreferencesMigration(sharedPreferences: container.read(sharedPreferencesProvider).requireValue).migrate();
    } catch (e, stackTrace) {
      Logger.bootstrap.error("preferences migration failed", e, stackTrace);
      if (env == Environment.dev) rethrow;
      Logger.bootstrap.info("clearing preferences");
      await container.read(sharedPreferencesProvider).requireValue.clear();
    }
  });

  // The log level decides this now. There is no second debug switch to keep in
  // sync, and the core reaches the same conclusion from the same value.
  final debug = kDebugMode || container.read(ConfigOptions.logLevel).isVerbose;

  if (PlatformUtils.isDesktop) {
    // The window has to be up before the splash comes off, but the log file and
    // the auto start service do not have to finish first: they touch different
    // stores and the splash stays until the window shows either way.
    final (_, _, _) = await (
      _init("window controller", () async {
        await container.read(windowNotifierProvider.future);
        final silentStart = container.read(Preferences.silentStart);
        Logger.bootstrap.debug("silent start [${silentStart ? "Enabled" : "Disabled"}]");
      }),
      // phase 3 — a log file is worth its cost on desktop, or while debugging.
      // On a phone in release it only burns storage nobody reads.
      _init("logging", () async => logFinish(keepFile: debug || PlatformUtils.isDesktop)),
      _init("auto start service", () => container.read(autoStartNotifierProvider.future)),
    ).wait;
  } else {
    await _init("logging", () async => logFinish(keepFile: debug || PlatformUtils.isDesktop));
  }

  // marks where this run begins, since the file now spans several
  logMarkRun(appInfo.format());
  Logger.bootstrap.info(appInfo.format());

  // Configs saved by an older build can carry keys the current core refuses.
  // The repair is a cleanup for old installs, not a precondition for this run,
  // so it waits for the repository in the background instead of holding the
  // first frame for up to three seconds.
  unawaited(
    _safeInit("profile repair", () async {
      await container.read(profileRepositoryProvider.future);
      await container.read(profileRepositoryProvider).requireValue.repairProfiles().run();
    }, timeout: 3000),
  );

  // The profile data is what the rest of the startup reads. Requesting these
  // together lets the provider graph resolve the shared dependency once instead
  // of paying for it in sequence.
  final (_, _, _, _) = await (
    _init("profile repository", () => container.read(profileRepositoryProvider.future)),
    _safeInit("active profile", () => container.read(activeProfileProvider.future), timeout: 1000),
    _init(
      "chain profile extra security",
      () => container.read(chainProfileNotifierProvider(ChainType.extraSecurity).future),
    ),
    _init("chain profile unblocker", () => container.read(chainProfileNotifierProvider(ChainType.unblocker).future)),
  ).wait;
  await _safeInit("hiddify-core", () => container.read(hiddifyCoreServiceProvider).init());

  // Eagerly listen to activeProxyNotifierProvider to force synchronous evaluation in microtasks,
  // avoiding lazy build-phase flushes and sibling dependency collisions on the Home page.
  container.listen(activeProxyNotifierProvider, (previous, next) {});

  if (!kIsWeb) {
    if (PlatformUtils.isAndroid) {
      await _safeInit("android display mode", () async {
        await FlutterDisplayMode.setHighRefreshRate();
      });
    }
  }

  Logger.bootstrap.info("bootstrap took [${stopWatch.elapsedMilliseconds}ms]");
  stopWatch.stop();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: SentryUserInteractionWidget(child: const App()),
    ),
  );

  if (!kIsWeb) {
    FlutterNativeSplash.remove();
  }

  if (!kIsWeb && PlatformUtils.isDesktop) {
    // The window comes back only now: the first frame is on the screen, so
    // the user sees the app and not an empty surface. A silent start keeps it
    // hidden, reachable from the tray.
    await _waitForFirstPaint();
    if (!container.read(Preferences.silentStart)) {
      await container.read(windowNotifierProvider.notifier).show(focus: false);
      Logger.bootstrap.debug("showing app window after the first frame");
    }
    // The tunnel and the tray come up after the window is on the screen. Both
    // take seconds - the core starts, the tunnel connects - and the user can
    // watch the app while that happens instead of staring at an empty window.
    await _safeInit(
      "restore previous connection",
      () => container.read(connectionNotifierProvider.notifier).restoreConnectionOnStartup(),
      timeout: 5000,
    );
    // The tray reads three providers before its first native call, which on a
    // cold release start takes longer than the second this used to allow; the
    // result was a tray that never appeared. It is not on the critical path,
    // so the timeout only stops a hang, it does not rush the work.
    await _safeInit("system tray", () => container.read(systemTrayNotifierProvider.future), timeout: 5000);
  }
  // SentryFlutter.s(DateTime.now().toUtc());
}

/// Waits until the first frame is actually on the screen.
///
/// [endOfFrame] says the frame was built, not that it was painted: the pixels
/// reach the window a moment later, and a window shown in between shows an
/// empty grey surface. The frame timings come back once the raster is done,
/// which is the first moment the window has something to show.
Future<void> _waitForFirstPaint() async {
  final painted = Completer<void>();
  void onTimings(List<FrameTiming> timings) {
    if (!painted.isCompleted) painted.complete();
  }

  SchedulerBinding.instance.addTimingsCallback(onTimings);
  try {
    await WidgetsBinding.instance.endOfFrame;
    await painted.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
  }
}

Future<T> _init<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  final stopWatch = Stopwatch()..start();
  Logger.bootstrap.info("initializing [$name]");
  Future<T> func() => timeout != null ? initializer().timeout(Duration(milliseconds: timeout)) : initializer();
  try {
    final result = await func();
    Logger.bootstrap.debug("[$name] initialized in ${stopWatch.elapsedMilliseconds}ms");
    return result;
  } catch (e, stackTrace) {
    Logger.bootstrap.error("[$name] error initializing", e, stackTrace);
    rethrow;
  } finally {
    stopWatch.stop();
  }
}

Future<T?> _safeInit<T>(String name, Future<T> Function() initializer, {int? timeout}) async {
  try {
    return await _init(name, initializer, timeout: timeout);
  } catch (e) {
    return null;
  }
}
