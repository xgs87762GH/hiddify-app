import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/logger/core_logger.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/log/model/log_level.dart' as config_log_level;
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_wrapper_stub.dart'
    if (dart.library.io) 'package:hiddify/hiddifycore/core_interface/core_interface_wrapper.dart';
import 'package:hiddify/hiddifycore/core_start_failure.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart' as logging;
import 'package:rxdart/rxdart.dart';

class HiddifyCoreService with InfraLogger {
  HiddifyCoreService(this.ref);
  final Ref ref;

  // CoreHiddifyCoreService() {}
  final core = getCoreInterface();

  CoreStatus currentState = const CoreStatus.stopped();
  final statusController = BehaviorSubject<CoreStatus>();
  final CallOptions? grpcOptions = null; //CallOptions(timeout: const Duration(milliseconds: 10000));
  final Map<String, StreamSubscription?> subscriptions = {};
  List<OutboundGroup> latest = [];

  /// Re-arms the status listener when the core's gRPC channel goes away.
  ///
  /// The channel is replaced on every setup (a resume, a core restart), and a
  /// listener opened on the old one errors out for good. Without this the app
  /// keeps whatever state it had when the channel died.
  Timer? _statusRearm;
  static const _minRearmDelay = Duration(seconds: 2);
  static const _maxRearmDelay = Duration(seconds: 30);
  Duration _rearmDelay = _minRearmDelay;

  Future<void> init() async {
    await setup()
        .mapLeft((e) {
          loggy.error(e);
          if (PlatformUtils.isIOS) return;
          statusController.add(const CoreStatus.stopped());
          ref.read(inAppNotificationControllerProvider).showErrorToast(e);
        })
        .map((_) {
          loggy.info("Hiddify-core setup done");
          ref.read(coreRestartSignalProvider.notifier).restart();
        })
        .run();
  }

  /// validates config by path and save it
  ///
  /// [path] is used to save validated config
  /// [tempPath] includes base config, possibly invalid
  /// [debug] indicates if debug mode (avoid in prod)

  TaskEither<String, Unit> validateConfigByPath(String path, String tempPath, bool debug) {
    return TaskEither(() async {
      try {
        final response = await core.fgClient.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
        if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      } catch (e) {
        await setup().run();
        final response = await core.fgClient.parse(ParseRequest(tempPath: tempPath, configPath: path, debug: false));
        if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      }
      return right(unit);
    });
  }

  TaskEither<String, String> generateFullConfigByPath(String path) {
    return TaskEither(() async {
      final response = await core.fgClient.parse(ParseRequest(configPath: path, debug: false));
      if (response.responseCode != ResponseCode.OK) return left("${response.responseCode} ${response.message}");
      return right(response.content);
    });
  }

  TaskEither<String, Unit> setup() {
    return TaskEither(() async {
      try {
        final directories = ref.read(appDirectoriesProvider).requireValue;
        final debug = kDebugMode || ref.read(ConfigOptions.logLevel).isVerbose;
        final setupResponse = await core.setup(directories, debug, 3);

        if (setupResponse.isNotEmpty) {
          return left(setupResponse);
        }

        await startListeningLogs("fg", core.fgClient);
        // await startListeningStatus("fg", core.fgClient);
        if (!core.isSingleChannel()) {
          await startListeningLogs("bg", core.bgClient);
        }
        statusController.add(currentState);
        await startListeningStatus("bg", core.bgClient);
        // ref.read(coreRestartSignalProvider.notifier).restart();
        return right(unit);
      } catch (e) {
        return left(e.toString());
      }
    });
  }

  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    return TaskEither(() async {
      loggy.debug("changing options");
      // latestOptions = options;
      try {
        final res = await core.fgClient.changeHiddifySettings(
          ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(options.toJson())),
        );
        if (res.messageType != MessageType.EMPTY) return left("${res.messageType} ${res.message}");
        await core.bgClient.changeHiddifySettings(
          ChangeHiddifySettingsRequest(hiddifySettingsJson: jsonEncode(options.toJson())),
        );
      } on GrpcError catch (e) {
        if (e.code == StatusCode.unavailable) {
          loggy.debug("background core is not started yet! $e");
        } else {
          rethrow;
        }
      }

      return right(unit);
    });
  }

  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      statusController.add(currentState = const CoreStatus.starting());
      loggy.debug("starting");
      final background = await core.setupBackground(path, name);
      if (background != const CoreStatus.started()) {
        statusController.add(currentState = const CoreStatus.stopped());
        return left(background.getCoreAlert() ?? const ConnectionFailure.unexpected("failed to start core"));
      }
      // Armed again on every connect, not only when there are two channels.
      // listenSingle drops a subscription for good when its stream errors, and
      // a gRPC connection being terminated does exactly that, so a listener
      // armed once at setup does not survive the engine restarting. Re-listening
      // is idempotent: listenSingle cancels the previous one for the same key.
      await startListeningLogs("fg", core.fgClient);
      if (!core.isSingleChannel()) {
        await startListeningLogs("bg", core.bgClient);
        await startListeningStatus("bg", core.bgClient);
      }
      // if (latestOptions != null) {
      //   await core.bgClient.changeHiddifySettings(
      //     ChangeHiddifySettingsRequest(
      //       hiddifySettingsJson: jsonEncode(latestOptions!.toJson()),
      //     ),
      //   );
      // }
      // final content = await File(path).readAsString();
      // loggy.debug("starting with content: $content");
      try {
        final res = await core.bgClient.start(
          StartRequest(
            configPath: path,
            configName: name,
            // configContent: content,
            disableMemoryLimit: disableMemoryLimit,
          ),
        );
        ref.read(coreRestartSignalProvider.notifier).restart();
        if (res.messageType != MessageType.ALREADY_STARTED && res.messageType != MessageType.EMPTY) {
          // The response path used to look for the word "denied" only, so
          // "operation not permitted" and Windows' privilege wording fell
          // through to a generic "start failed". Same classifier as the error
          // path now, so both report the cause the user can act on.
          final failure = CoreStartFailure.fromMessage(res.message);
          currentState = CoreStatus.stopped(alert: _alertFor(failure), message: res.message);

          statusController.add(currentState);

          return left(failure);
        }
      } on GrpcError catch (e) {
        loggy.error("failed to start bg core: $e");
        ref.read(coreRestartSignalProvider.notifier).restart();
        final message = e.message ?? "";
        if (e.code == StatusCode.unavailable) {
          return left(const ConnectionFailure.unexpected("background core is not started yet!"));
        }
        if (message.isEmpty) {
          return left(const ConnectionFailure.unexpected("failed to start background core"));
        }
        // The core words these itself, in English on every system language, so
        // the text is the only thing that tells "elevate the app" apart from
        // "this config is broken". One place decides, and it covers Windows'
        // two spellings, Linux and macOS (issues #2276, #2224).
        return left(CoreStartFailure.fromMessage(message));
      }

      // if (res.messageType != MessageType.EMPTY) return left(res);

      return right(unit);
    });
  }

  /// The alert that goes with a start failure, for the status the UI reads.
  ///
  /// [CoreStartFailure.fromMessage] already produced the failure that is
  /// returned to the caller; this only mirrors it onto the status stream, which
  /// is what the home screen and the tray show.
  static CoreAlert _alertFor(ConnectionFailure failure) {
    return switch (failure) {
      MissingVpnPermission() || MissingPrivilege() => CoreAlert.requestVPNPermission,
      InvalidConfig() || InvalidConfigOption() => CoreAlert.emptyConfiguration,
      _ => CoreAlert.startFailed,
    };
  }

  TaskEither<String, Unit> stop() {
    return TaskEither(() async {
      loggy.debug("stopping");
      var errMsg = "";
      try {
        await core.bgClient.stop(Empty());
      } on GrpcError catch (e) {
        // A terminated channel is not a failed stop: the core went away with
        // it, which is what was asked for.
        if (isConnectionTerminated(e)) {
          loggy.debug("stop raced with the channel closing: ${e.message}");
        } else {
          errMsg = e.message ?? "failed to stop core: $e";
          loggy.error("failed to stop bg core: $e");
        }
      } catch (e) {
        loggy.error("failed to stop bg core: $e");
        // left("failed to stop core: $e");
      }
      if (!await core.stop()) {}
      statusController.add(currentState = const CoreStatus.stopped());
      if (errMsg.isNotEmpty) return left(errMsg);
      return right(unit);
    });
  }

  /// Whether a gRPC error is only the channel being torn down underneath us.
  ///
  /// gRPC reports a dead connection as UNKNOWN with an HTTP/2 message, which is
  /// what every resume, every core restart and every quit produces. Three call
  /// sites used to compare `code` and message text with three different
  /// spellings; this is the one place that decides now.
  ///
  /// Public because the repositories that wrap these streams need the same
  /// answer before they decide whether a failure is worth an error line.
  static bool isConnectionTerminated(Object error) {
    if (error is! GrpcError) return false;
    if (error.code == StatusCode.unavailable) return true;
    if (error.code != StatusCode.unknown && error.code != StatusCode.cancelled) return false;
    final message = error.message ?? "";
    return message.isEmpty || message.contains("HTTP/2") || message.contains("Connection");
  }

  /// Applies a changed config to the running core: first as a hot reload, which keeps the core
  /// (and its connections) running; when the core cannot hot reload it (e.g. the TUN inbound
  /// changed) or the hot reload fails, the core is restarted instead.
  TaskEither<String, Unit> reload(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      loggy.debug("hot reloading");
      try {
        final res = await core.bgClient.hotReload(
          StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit),
        );
        if (res.messageType == MessageType.EMPTY) return right(unit);
        loggy.info("hot reload not applied, restarting: ${res.messageType} ${res.message}");
      } on GrpcError catch (e) {
        loggy.warning("hot reload failed, restarting: $e");
      }
      return restart(path, name, disableMemoryLimit).run();
    });
  }

  TaskEither<String, Unit> restart(String path, String name, bool disableMemoryLimit) {
    return TaskEither(() async {
      loggy.debug("restarting");
      // if (!await core.restart(path, name)) {
      try {
        final res = await core.bgClient.restart(
          StartRequest(configPath: path, configName: name, disableMemoryLimit: disableMemoryLimit, delayStart: true),
        );
        if (res.messageType != MessageType.EMPTY) return left("${res.messageType} ${res.message}");
      } on GrpcError catch (e) {
        // A restart tears the channel down before it answers, so a terminated
        // connection here means the restart did happen.
        if (!isConnectionTerminated(e)) {
          loggy.error("failed to restart bg core: $e");
          return left("${e.message}");
        }
        loggy.debug("restart closed the channel: ${e.message}");
      }

      // The core runs again behind a connection the old listener cannot use.
      _rearmDelay = _minRearmDelay;
      _scheduleStatusRearm();
      return right(unit);
      // await stop().run();
      // return await start(path, name, disableMemoryLimit).run();
      // }
      // if (!core.isSingleChannel()) {
      //   await startListeningStatus("bg", core.bgClient);
      //   await startListeningLogs("bg", core.bgClient);
      // }
      // return right(unit);
    });
  }

  TaskEither<String, Unit> resetTunnel() {
    return TaskEither(() async {
      // only available on iOS (and macOS later)
      if (!PlatformUtils.isIOS) {
        throw UnimplementedError("reset tunnel function unavailable on platform");
      }

      // loggy.debug("resetting tunnel");
      final res = await core.resetTunnel();
      if (res) {
        return right(unit);
      }
      return left("failed to reset tunnel");
    });
  }

  // Stream<List<OutboundGroup>> watchGroups() async* {
  //   loggy.debug("watching groups");
  //   yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items);
  //   // res?.cancel();
  // }

  Stream<OutboundGroup?> watchGroup() async* {
    loggy.debug("watching group");
    // interrupt managed by core

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }
    try {
      yield* core.bgClient.outboundsInfo(Empty()).map((event) => event.items.isEmpty ? null : event.items.first);
    } catch (e) {
      loggy.error("error watching group: $e");
      rethrow;
    }
    // //emitting first event immediately
    // yield* core.bgClient.outboundsInfo(Empty()).take(1).map((event) => event.items.isEmpty ? null : event.items.first);
    // //emitting other event after every 4 seconds(latest event)
    // yield* core.bgClient.outboundsInfo(Empty()).throttleTime(const Duration(seconds: 4), leading: false, trailing: true).map((event) => event.items.isEmpty ? null : event.items.first);
  }

  Stream<List<OutboundGroup>> watchActiveGroups() async* {
    loggy.info("watching active groups");

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
    }

    try {
      yield* core.bgClient
          .mainOutboundsInfo(Empty())
          .map((event) {
            return latest = event.items.toList();
          })
          .startWith(latest);
    } catch (e) {
      loggy.error("error watching active groups: $e");
      rethrow;
    }
  }

  //
  // Stream<SingboxStatus> watchStatus() => _status;

  ResponseStream<SystemInfo> watchStats() {
    loggy.debug("watching stats");
    try {
      return core.bgClient.getSystemInfoStream(Empty());
    } catch (e) {
      loggy.error("error watching stats: $e");
      rethrow;
    }
  }

  TaskEither<String, Unit> selectOutbound(String groupTag, String outboundTag) {
    return TaskEither(() async {
      loggy.debug("selecting outbound");
      try {
        final res = await core.bgClient.selectOutbound(
          SelectOutboundRequest(groupTag: groupTag, outboundTag: outboundTag),
          // One second is not enough on a loaded machine, and the call is only
          // a lookup and a pointer swap inside the core. A timeout here showed
          // up as a failed switch that had actually happened.
          options: CallOptions(timeout: const Duration(seconds: 5)),
        );
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error selecting outbound: $e");
        rethrow;
      }
    });
  }

  TaskEither<String, Unit> urlTest(String tag) {
    return TaskEither(() async {
      loggy.debug("url test");
      try {
        // A test of a whole group is as slow as its slowest proxy, so this one
        // gets a timeout instead of the default (none): without it a core that
        // stops answering left the button spinning forever.
        final res = await core.bgClient.urlTest(
          UrlTestRequest(tag: tag),
          options: CallOptions(timeout: const Duration(seconds: 30)),
        );
        if (res.code != ResponseCode.OK) return left("${res.code} ${res.message}");

        return right(unit);
      } catch (e) {
        loggy.error("error in url test: $e");
        rethrow;
      }
    });
  }

  // The 300-message buffer and its BehaviorSubject are gone. They existed so
  // the logs page could show history when it opened, and only ever held the
  // engine's lines. The in-memory ring in core/logger does that for every
  // category, so the page reads it instead.

  // TaskEither<String, WarpResponse> generateWarpConfig({
  //   required String licenseKey,
  //   required String previousAccountId,
  //   required String previousAccessToken,
  // }) {
  //   return TaskEither(() async {
  //     loggy.debug("generating warp config");
  //     final warpConfig = await core.fgClient.generateWarpConfig(
  //       GenerateWarpConfigRequest(
  //         licenseKey: licenseKey,
  //         accountId: previousAccountId,
  //         accessToken: previousAccessToken,
  //       ),
  //     );
  //     // if (warpConfig.code != ResponseCode.OK) return left("${warpConfig.code} ${warpConfig.message}");
  //     final WarpResponse warp = (
  //       log: warpConfig.log,
  //       accountId: warpConfig.account.accountId,
  //       accessToken: warpConfig.account.accessToken,
  //       wireguardConfig: jsonEncode(warpConfig.config.toProto3Json()),
  //     );
  //     return right(warp);
  //   });
  // }

  Stream<CoreStatus> watchStatus() async* {
    await startListeningStatus("bg", core.bgClient);
    yield* statusController.stream;
    // .endWith(const CoreStatus.stopped());
  }

  Future<void> startListeningStatus(String key, CoreClient cc) async {
    await listenSingle<CoreStatus>(
      "${key}StatusListener",
      () => cc
          .coreInfoListener(Empty(), options: grpcOptions)
          // A closed or broken channel is the ordinary end of this listener: it
          // happens on every resume and every core restart. It is not a failure
          // of the tunnel, so it is not logged as one any more; the re-arm
          // below recovers and the last known state stays on screen meanwhile.
          .doOnCancel(() => loggy.debug("status listener cancelled"))
          .doOnDone(() {
            loggy.debug("status listener done");
            _scheduleStatusRearm();
          })
          // No `endWith(stopped)` here any more. It pushed a STOPPED status
          // whenever the listener closed, so a resume 鈥?which replaces the
          // channel 鈥?told the UI the tunnel had stopped while it was still
          // up: the connect button flipped to "Connect" and the proxies page
          // emptied until the next event arrived. A real stop is reported by
          // the core itself.
          .map((event) {
            _rearmDelay = _minRearmDelay;
            currentState = CoreStatus.fromCoreInfo(event);
            statusController.add(currentState);
            return currentState;
          }),
      onError: (error) {
        // Same story: the channel was terminated, which gRPC reports as an
        // error even though nothing went wrong inside the app.
        loggy.debug("status listener ended: $error");
        _scheduleStatusRearm();
      },
    );
  }

  /// Opens the status listener again after [_rearmDelay], doubling the wait up
  /// to [_maxRearmDelay] while the core stays unreachable.
  void _scheduleStatusRearm() {
    if (_statusRearm?.isActive ?? false) return;
    final delay = _rearmDelay;
    loggy.debug("re-arming status listener in $delay");
    _statusRearm = Timer(delay, () async {
      _statusRearm = null;
      if (!core.isInitialized()) return;
      try {
        await startListeningStatus("bg", core.bgClient);
      } catch (e) {
        loggy.debug("failed to re-arm status listener: $e");
      }
    });
    final doubled = _rearmDelay * 2;
    _rearmDelay = doubled < _maxRearmDelay ? doubled : _maxRearmDelay;
  }

  Future<void> startListeningLogs(String key, CoreClient cc) async {
    final logLevel = ref.read(ConfigOptions.logLevel);
    final coreLogLevel = getCoreLogLevel(logLevel);
    final listenKey = "${key}LogListener";
    // await stopListenSingle(listenKey);
    await listenSingle<LogMessage>(listenKey, () {
      return cc.logListener(LogRequest(level: coreLogLevel), options: grpcOptions).map((event) {
        // Handle incoming event
        // One message becomes one record. The old code split on newlines
        // first, but the engine already sends one line per message, so the
        // split only allocated a list and multiplied the work per burst.
        coreLogFor(event.type).log(getLogLevel(event.level), event.message);
        return event;
      });
    });
  }

  Future<void> stopListenSingle(String key) async {
    // Collect keys to remove first
    final keysToRemove = subscriptions.entries
        .where((entry) => entry.key.startsWith(key))
        .map((entry) => entry.key)
        .toList();

    // Cancel and remove
    for (final k in keysToRemove) {
      final sub = subscriptions[k];
      await sub?.cancel(); // cancel the subscription

      subscriptions.remove(k);
    }
  }

  Future<StreamSubscription<T>?> listenSingle<T>(
    String key,
    Stream<T> Function() stream, {
    Function(dynamic error)? onError,
  }) async {
    if (subscriptions.containsKey(key)) {
      // return subscriptions[key] as StreamSubscription<T>?;
      await stopListenSingle(key);
    }
    subscriptions[key] = null;
    subscriptions[key] = stream().listen(
      (event) {
        // loggy.debug(event);
      },
      cancelOnError: true,
      onError: (error) {
        // A terminated channel is the ordinary end of a subscription that was
        // opened on a connection the core has since replaced 鈥?it happens on
        // every resume and every restart. Logging it as an error with a stack
        // trace buried the errors that do matter.
        if (error is GrpcError && isConnectionTerminated(error)) {
          loggy.debug("subscription [$key] ended with the channel: ${error.message}");
        } else {
          loggy.error('Stream error: $error');
        }
        onError?.call(error);
        subscriptions[key]?.cancel();
        subscriptions.remove(key);
      },
    );
    return subscriptions[key] as StreamSubscription<T>?;
  }

  /// Six engine levels onto six logging levels, nothing merged.
  ///
  /// TRACE used to have no case here and fell into the default, so trace lines
  /// arrived looking as important as info and could not be filtered out. FATAL
  /// used to collapse into error because loggy had nothing above it.
  logging.Level getLogLevel(LogLevel level) {
    return switch (level) {
      LogLevel.TRACE => logging.Level.FINEST,
      LogLevel.DEBUG => logging.Level.FINE,
      LogLevel.INFO => logging.Level.INFO,
      LogLevel.WARNING => logging.Level.WARNING,
      LogLevel.ERROR => logging.Level.SEVERE,
      LogLevel.FATAL => logging.Level.SHOUT,
      // the proto enum is a generated class, so a default is unavoidable
      _ => logging.Level.INFO,
    };
  }

  LogLevel getCoreLogLevel(config_log_level.LogLevel level) {
    return switch (level) {
      config_log_level.LogLevel.trace => LogLevel.TRACE,
      config_log_level.LogLevel.debug => LogLevel.DEBUG,
      config_log_level.LogLevel.info => LogLevel.INFO,
      config_log_level.LogLevel.warn => LogLevel.WARNING,
      config_log_level.LogLevel.error => LogLevel.ERROR,
      config_log_level.LogLevel.fatal => LogLevel.FATAL,
      config_log_level.LogLevel.panic => LogLevel.FATAL,
      // ignore: unreachable_switch_case
      _ => LogLevel.INFO, // Default case
    };
  }

  Future<void> closeFront() async {
    if (!core.isInitialized()) {
      return;
    }
    // The app is going to the background, so nothing is listening for a while.
    // A re-arm scheduled by the dying channel must not fire into the void.
    _statusRearm?.cancel();
    _statusRearm = null;
    if (!core.isSingleChannel()) {
      await stopListenSingle("fg");
      await stopListenSingle("bg");
      // Only one of the two modes matches how the channel was opened, so the
      // other one always throws. Both are attempted and the failure is logged.
      try {
        await core.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL_INSECURE));
      } catch (e) {
        loggy.debug("closing fg client in insecure mode failed: $e");
      }
      try {
        await core.fgClient.close(CloseRequest(mode: SetupMode.GRPC_NORMAL));
      } catch (e) {
        loggy.debug("closing fg client in normal mode failed: $e");
      }
    }
  }

  TaskEither<String, LANIPResponse> getLANIP() {
    return TaskEither(() async {
      try {
        final response = await core.fgClient.getLANIP(Empty());
        return right(response);
      } catch (e) {
        loggy.error("failed to get LAN IP: $e");
        return left(e.toString());
      }
    });
  }
}
