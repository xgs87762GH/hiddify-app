import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/window/window_geometry.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'window_notifier.g.dart';

const minimumWindowSize = Size(368, 568);
const defaultWindowSize = Size(868, 668);

/// Hides the window the runner already put on the screen.
///
/// The Windows runner shows the window as soon as the engine starts, and the
/// app paints nothing on it until it renders its first frame. The boot takes
/// seconds, so the window is hidden right away and shown again once there is
/// something to show: an empty grey rectangle reads as a broken app.
Future<void> hideWindowUntilReady() async {
  await windowManager.ensureInitialized();
  await windowManager.hide();
}

@Riverpod(keepAlive: true)
class WindowNotifier extends _$WindowNotifier with AppLogger {
  @override
  Future<void> build() async {
    if (!PlatformUtils.isDesktop) return;

    // if (Platform.isWindows) {
    //   loggy.debug("ensuring single instance");
    //   await WindowsSingleInstance.ensureSingleInstance([], "Hiddify");
    // }

    await windowManager.ensureInitialized();
    await initWindowState();
  }

  Future<void> saveWindowState() async {
    if (await windowManager.isMaximized()) {
      await ref.read(Preferences.windowMaximized.notifier).update(true);
    } else {
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();

      await ref.read(Preferences.windowMaximized.notifier).update(false);
      await ref.read(Preferences.windowSize.notifier).update(size);
      await ref.read(Preferences.windowPosition.notifier).update(position);
    }
  }

  Future<void> initWindowState() async {
    final isMaximized = ref.read(Preferences.windowMaximized);
    loggy.debug("window state. maximized: $isMaximized");
    final savedSize = ref.read(Preferences.windowSize);
    final savedPosition = ref.read(Preferences.windowPosition);
    final silentStart = ref.read(Preferences.silentStart);
    loggy.debug("window state. silent start: ${silentStart ? "Enabled" : "Disabled"}");

    final displays = await screenRetriever.getAllDisplays();
    final savedDisplay = savedPosition == null ? null : displayForSavedWindow(displays, savedPosition & savedSize);
    final targetDisplay = savedDisplay ?? await screenRetriever.getPrimaryDisplay();
    final targetScale = displayScale(targetDisplay);
    final workArea = physicalWorkArea(targetDisplay);
    final minimumPhysicalSize = minimumWindowSize * targetScale;

    final Rect window;
    if (savedDisplay != null && savedPosition != null) {
      final savedScale = displayScale(savedDisplay);
      window = fitWindowToWorkArea(
        Rect.fromLTWH(
          savedPosition.dx * savedScale,
          savedPosition.dy * savedScale,
          savedSize.width * savedScale,
          savedSize.height * savedScale,
        ),
        workArea,
        minimumSize: minimumPhysicalSize,
      );
    } else {
      window = centeredWindow(
        workArea,
        defaultWindowSize * targetScale,
        minimumSize: minimumPhysicalSize,
      );
    }
    loggy.debug("window state. restoring ${window.size} at ${window.topLeft} (scale: $targetScale)");

    final startDpr = windowManager.getDevicePixelRatio();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(size: window.size / startDpr, minimumSize: minimumWindowSize),
    );
    // Move first: the window adopts the target display's DPI, which is the only
    // way to set the size in the units the geometry was saved in.
    await windowManager.setPosition(window.topLeft / startDpr);
    var dpr = await _settledDpr(targetScale, const Duration(milliseconds: 250));
    if (silentStart) {
      loggy.debug("silent start, remain hidden accessible via tray");
    }
    // The window itself is shown by the bootstrap once the first frame is on
    // screen, so nothing here puts an empty surface in front of the user.
    // From here on the user can see the window, so every step below corrects
    // something visible instead of holding the first frame.
    if ((dpr - targetScale).abs() > 0.01) {
      // Place it for the scale it actually got before waiting any longer: at
      // the wrong DPR the saved position points at a different display, and the
      // window would sit there for the whole wait.
      await _applyGeometry(window, windowManager.getDevicePixelRatio());
      dpr = await _settledDpr(targetScale, const Duration(milliseconds: 500));
    }
    await _applyGeometry(window, dpr);
    if (isMaximized) {
      await windowManager.maximize();
      loggy.debug("restoring window to maximized state");
    }
  }

  /// Sets the physical [window] for the given [dpr], the units window_manager
  /// takes. Called again whenever the display scale settles on a new value.
  Future<void> _applyGeometry(Rect window, double dpr) async {
    await windowManager.setSize(window.size / dpr);
    await windowManager.setPosition(window.topLeft / dpr);
  }

  Future<double> _settledDpr(double expected, Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    var dpr = windowManager.getDevicePixelRatio();
    while ((dpr - expected).abs() > 0.01 && stopwatch.elapsed < timeout) {
      await Future.delayed(const Duration(milliseconds: 25));
      dpr = windowManager.getDevicePixelRatio();
    }
    if ((dpr - expected).abs() > 0.01) {
      loggy.debug("window state. display scale did not settle on $expected (got $dpr)");
    }
    return dpr;
  }

  Future<void> show({bool focus = true}) async {
    await windowManager.show();
    if (focus) await windowManager.focus();
    if (Platform.isMacOS) {
      await windowManager.setSkipTaskbar(false);
    }
  }

  Future<void> hide() async {
    await windowManager.hide();
    if (Platform.isMacOS) {
      await windowManager.setSkipTaskbar(true);
    }
  }

  Future<void> showOrHide() async {
    if (await windowManager.isVisible()) {
      await hide();
    } else {
      await show();
    }
  }

  Future<void> exit() async {
    await ref
        .read(connectionNotifierProvider.notifier)
        .abortConnection()
        .timeout(const Duration(seconds: 2))
        .catchError((e) {
          loggy.warning("error aborting connection on quit", e);
        });
    await trayManager.destroy();
    await windowManager.destroy();
  }
}
