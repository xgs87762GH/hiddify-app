import 'dart:async';

import 'package:dartx/dartx.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:meta/meta.dart';
import 'package:neat_periodic_task/neat_periodic_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profiles_update_notifier.g.dart';

typedef ProfileUpdateStatus = ({String name, bool success});

@Riverpod(keepAlive: true)
class ForegroundProfilesUpdateNotifier extends _$ForegroundProfilesUpdateNotifier with AppLogger {
  static const prefKey = "profiles_update_check";
  static const interval = Duration(minutes: 15);

  /// How long one profile may take before the run moves on to the next.
  ///
  /// A subscription download is bounded by the HTTP client, but validating the
  /// result is a call into the core, and that one has no timeout of its own. A
  /// core that stops answering used to hold the whole run — and with it the
  /// scheduler's only worker — until the package killed it after five minutes,
  /// which is the "[FAILED] profiles update worker, timeout exceeded" in the
  /// log.
  static const _perProfileTimeout = Duration(minutes: 2);

  /// The scheduler's timeout is not a cancellation: the run keeps going in the
  /// background while the next one starts, and two runs calling the core at the
  /// same time can hang it. The guard makes the second one a no-op instead.
  bool _running = false;

  @override
  Stream<ProfileUpdateStatus?> build() {
    var cycleCount = 0;
    _scheduler = NeatPeriodicTaskScheduler(
      name: 'profiles update worker',
      interval: interval,
      // Not a deadline for the work: the package treats passing it as a failed
      // run and shouts about it at FATAL, which is how a slow batch of
      // subscriptions turned into "[FAILED] ... timeout exceeded" in the log.
      // Each profile is bounded on its own below, and the guard keeps runs from
      // overlapping, so this only has to be long enough not to interrupt a
      // large batch.
      timeout: const Duration(minutes: 30),
      task: () async {
        loggy.debug("cycle [${cycleCount++}]");
        await updateProfiles();
      },
    );

    ref.onDispose(() async {
      await _scheduler?.stop();
      _scheduler = null;
    });

    if (ref.watch(Preferences.introCompleted)) {
      loggy.debug("intro done, starting");
      _scheduler?.start();
    } else {
      loggy.debug("intro in process, skipping");
    }
    return const Stream.empty();
  }

  NeatPeriodicTaskScheduler? _scheduler;
  bool _forceNextRun = false;

  Future<void> trigger() async {
    loggy.debug("triggering update");
    _forceNextRun = true;
    await _scheduler?.trigger();
  }

  @visibleForTesting
  Future<void> updateProfiles() async {
    if (_running) {
      // The previous run is still going (its scheduler timeout has passed).
      // Dropping this one keeps a single run talking to the core.
      loggy.debug("previous update still running, skipping this cycle");
      return;
    }
    _running = true;
    var force = false;
    if (_forceNextRun) {
      force = true;
      _forceNextRun = false;
    }

    try {
      final previousRun = DateTime.tryParse(ref.read(sharedPreferencesProvider).requireValue.getString(prefKey) ?? "");

      if (!force && previousRun != null && previousRun.add(interval) > DateTime.now()) {
        loggy.debug("too soon! previous run: [$previousRun]");
        return;
      }
      loggy.debug("${force ? "[FORCED] " : ""}running, previous run: [$previousRun]");

      final remoteProfiles = await ref
          .read(profileRepositoryProvider)
          .requireValue
          .watchAll()
          .map(
            (event) => event.getOrElse((f) {
              loggy.error("error getting profiles");
              throw f;
            }).whereType<RemoteProfileEntity>(),
          )
          .first
          .timeout(const Duration(seconds: 30));

      final toUpdate = remoteProfiles.where((profile) {
        final updateInterval = profile.options?.updateInterval;
        final shouldUpdate =
            force || updateInterval != null && updateInterval <= DateTime.now().difference(profile.lastUpdate);
        if (!shouldUpdate) {
          loggy.debug(
            "skipping profile [${profile.id}] update. last successful update: [${profile.lastUpdate}] - interval: [${profile.options?.updateInterval}]",
          );
        }
        return shouldUpdate;
      }).toList();

      var successCount = 0;
      final failedNames = <String>[];
      // Sequential on purpose: validation and the active-profile reconnect share
      // one native core that is not safe to call concurrently (it can hang).
      for (final profile in toUpdate) {
        try {
          await ref
              .read(updateProfileNotifierProvider(profile.id).notifier)
              .updateProfile(profile, isBulk: true)
              .timeout(_perProfileTimeout);
        } on TimeoutException {
          // One unresponsive subscription must not cost the whole run, and its
          // provider has to be released too: a notifier that stays loading
          // refuses every later update of that profile.
          loggy.warning("update of profile [${profile.id}] timed out, moving on");
          ref.read(updateProfileNotifierProvider(profile.id).notifier).resetStuck();
          failedNames.add(profile.name);
          continue;
        }
        if (ref.read(updateProfileNotifierProvider(profile.id)).hasError) {
          failedNames.add(profile.name);
        } else {
          successCount++;
        }
      }

      // Only a manual run (forced) reports; the periodic background run stays silent.
      if (force && (successCount > 0 || failedNames.isNotEmpty)) {
        final t = ref.read(translationsProvider).requireValue;
        final notification = ref.read(inAppNotificationControllerProvider);
        if (failedNames.isEmpty) {
          notification.showSuccessToast(t.pages.profiles.msg.update.bulkSuccess(count: successCount));
        } else {
          notification.showErrorToast(
            t.pages.profiles.msg.update.bulkPartial(
              success: successCount,
              failed: failedNames.length,
              names: failedNames.join(", "),
            ),
          );
        }
      }
    } finally {
      // Released before the timestamp is written, so a failed write cannot leave
      // the guard set and silently disable every later run.
      _running = false;
      await ref.read(sharedPreferencesProvider).requireValue.setString(prefKey, DateTime.now().toIso8601String());
    }
  }
}
