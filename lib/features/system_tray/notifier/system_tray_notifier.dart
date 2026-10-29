import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'system_tray_notifier.g.dart';

@Riverpod(keepAlive: true)
class SystemTrayNotifier extends _$SystemTrayNotifier with TrayListener, AppLogger {
  bool listenerAdded = false;
  @override
  Future<void> build() async {
    assert(PlatformUtils.isDesktop);
    if (!listenerAdded) {
      trayManager.addListener(this);
      listenerAdded = true;
    }
    final t = await ref.watch(translationsProvider.future);
    // Neither the proxy stream nor the connection stream has emitted yet on a
    // cold start - the core has just come up - and waiting for their first
    // event is what used to hold the tray until its timeout. The tray renders
    // from whatever the streams hold right now, and the listeners keep it in
    // sync from then on, which it never did before beyond the first render.
    ref.listen(activeProxyNotifierProvider, (_, _) => _scheduleRefresh(t));
    ref.listen(connectionNotifierProvider, (_, _) => _scheduleRefresh(t));
    // The first render is scheduled rather than fired from a listener: a
    // fireImmediately callback would read providers while the graph is still
    // being iterated, which riverpod reports as a concurrent modification.
    _scheduleRefresh(t);
  }

  bool _refreshScheduled = false;

  /// Refreshes the tray after the current update is over.
  ///
  /// A listener fires while the provider graph is being iterated - that is
  /// what happens when the core reports a new connection state - and reading
  /// providers from there is what riverpod reports as a concurrent
  /// modification. One microtask later the reads are outside that update.
  void _scheduleRefresh(Translations t) {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    scheduleMicrotask(() {
      _refreshScheduled = false;
      _refreshTray(t);
    });
  }

  Future<void> _refreshTray(Translations t) async {
    final proxy = ref.read(activeProxyNotifierProvider).valueOrNull ?? OutboundInfo(urlTestDelay: 0);
    final connection = ref.read(connectionNotifierProvider).valueOrNull ?? const ConnectionStatus.disconnected();
    final status = _modifyConnectionStatus(connection, proxy.urlTestDelay);
    final serviceMode = ref.read(ConfigOptions.serviceMode);

    await trayManager.setIcon(_trayIconPath(status), isTemplate: PlatformUtils.isMacOS);
    if (!PlatformUtils.isLinux) await trayManager.setToolTip(_trayTooltip(status, proxy.urlTestDelay, t));
    await trayManager.setContextMenu(_trayMenu(status, serviceMode, t));
  }

  Menu _trayMenu(ConnectionStatus connection, ServiceMode serviceMode, Translations t) => Menu(
    items: [
      if (PlatformUtils.isLinux) ...[MenuItem(key: 'dashboard', label: t.common.dashboard), MenuItem.separator()],
      MenuItem(
        key: 'connection',
        label: switch (connection) {
          Disconnected() => t.connection.connect,
          Connecting() => t.connection.connecting,
          Connected() || Waiting() || NoAvailableProxies() => t.connection.disconnect,
          Disconnecting() => t.connection.disconnecting,
          HotReloading() => t.connection.hotReloading,
        },
        disabled: connection.isSwitching,
      ),
      MenuItem.submenu(
        label: t.pages.settings.inbound.serviceMode,
        icon: Assets.images.trayIconIco,
        submenu: Menu(
          items: [
            ...ServiceMode.values.map(
              (e) => MenuItem.checkbox(checked: e == serviceMode, key: e.name, label: e.present(t)),
            ),
          ],
        ),
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: t.common.quit),
    ],
  );

  String _trayIconPath(ConnectionStatus status) {
    final isDarkMode = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    const images = Assets.images;
    final isWindows = PlatformUtils.isWindows;
    switch (status) {
      case Connected():
        return isWindows ? images.trayIconConnectedIco : images.trayIconConnectedPng.path;
      case Connecting():
      case Waiting():
      case NoAvailableProxies():
      case Disconnecting():
      case HotReloading():
        return isWindows ? images.trayIconDisconnectedIco : images.trayIconDisconnectedPng.path;
      case Disconnected():
        return isWindows
            ? isDarkMode
                  ? images.trayIconIco
                  : images.trayIconDarkIco
            : isDarkMode
            ? images.trayIconDarkPng.path
            : images.trayIconPng.path;
    }
  }

  String _trayTooltip(ConnectionStatus connection, int urlTestDelay, Translations t) {
    final r = "${Constants.appName} - ${connection.present(t)}";
    if (connection is Connected) {
      if (Platform.isMacOS) windowManager.setBadgeLabel("${urlTestDelay}ms");
      return '$r : ${urlTestDelay}ms"';
    } else {
      if (Platform.isMacOS) windowManager.setBadgeLabel("-ms");
      return r;
    }
  }

  ConnectionStatus _modifyConnectionStatus(ConnectionStatus connection, int urlTestDelay) {
    if (connection is Connected) {
      return ConnectionConst.isValidDelay(urlTestDelay) ? const Connected() : const Connecting();
    } else {
      return connection;
    }
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    // if (menuItem.key == 'dashboard') {
    //   await ref.read(windowNotifierProvider.notifier).open();
    // }
    if (menuItem.key == 'dashboard') {
      await ref.read(windowNotifierProvider.notifier).show();
    } else if (menuItem.key == 'connection') {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    } else if (menuItem.key == 'quit') {
      await ref.read(windowNotifierProvider.notifier).exit();
    } else {
      final newMode = ServiceMode.values.byName(menuItem.key!);
      loggy.debug("switching service mode: [$newMode]");
      await ref.read(ConfigOptions.serviceMode.notifier).update(newMode);
    }
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    // if (Platform.isMacOS) {
    //   await trayManager.popUpContextMenu();
    // } else {
    //   await ref.read(windowNotifierProvider.notifier).hideOrShow();
    // }
    await ref.read(windowNotifierProvider.notifier).showOrHide();
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }
}
