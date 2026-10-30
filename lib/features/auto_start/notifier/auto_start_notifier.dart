import 'dart:async';
import 'dart:io';

import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'auto_start_notifier.g.dart';

@Riverpod(keepAlive: true)
class AutoStartNotifier extends _$AutoStartNotifier with InfraLogger {
  Timer? _timer;

  @override
  Future<bool> build() async {
    if (!PlatformUtils.isDesktop) return false;
    final appInfo = ref.watch(appInfoProvider).requireValue;
    launchAtStartup.setup(
      appName: appInfo.name,
      appPath: Platform.resolvedExecutable,
      packageName: "Hiddify.HiddifyNext",
    );
    // Missing HKCU\...\Run (fresh Windows) or a failed registry open must not
    // abort bootstrap: treat any read failure as "disabled" so runApp still runs.
    final isEnabled = await _isEnabledSafe();
    loggy.info("auto start is [${isEnabled ? "Enabled" : "Disabled"}]");
    _startTimer();
    ref.onDispose(() => _timer?.cancel());
    return isEnabled;
  }

  /// [launchAtStartup.isEnabled] opens the Run key without handling absence.
  Future<bool> _isEnabledSafe() async {
    try {
      return await launchAtStartup.isEnabled();
    } catch (e, st) {
      loggy.warning("auto start status unavailable; treating as disabled", e, st);
      return false;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 15), (timer) => updateStatus());
  }

  Future<bool> updateStatus() async {
    loggy.debug("update auto start status");
    final isEnabled = await _isEnabledSafe();
    state = AsyncValue.data(isEnabled);
    return isEnabled;
  }

  Future<void> enable() async {
    loggy.debug("enabling auto start");
    await launchAtStartup.enable();
    state = const AsyncValue.data(true);
  }

  Future<void> disable() async {
    loggy.debug("disabling auto start");
    await launchAtStartup.disable();
    state = const AsyncValue.data(false);
  }
}
