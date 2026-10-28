import 'dart:async';

import 'package:dio/dio.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/utils/throttler.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/proxy_failover.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/ip_info_entity.dart' as oldipinfo;
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';

import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'active_proxy_notifier.g.dart';

@riverpod
class IpInfoNotifier extends _$IpInfoNotifier with AppLogger {
  @override
  Future<oldipinfo.IpInfo> build() async {
    ref.disposeDelay(const Duration(seconds: 20));
    final cancelToken = CancelToken();
    Timer? timer;
    ref.onDispose(() {
      loggy.debug("disposing");
      cancelToken.cancel();
      timer?.cancel();
    });

    ref.listen(serviceRunningProvider, (_, next) => _idle = false);

    final autoCheck = ref.watch(Preferences.autoCheckIp);
    final serviceRunning = ref.watch(serviceRunningProvider);
    // loggy.debug(
    //   "idle? [$_idle], forced? [$_forceCheck], connected? [$serviceRunning]",
    // );
    if (!_forceCheck && !serviceRunning) {
      throw const ServiceNotRunning();
    } else if ((_idle && !_forceCheck) || (!_forceCheck && serviceRunning && !autoCheck)) {
      throw const UnknownIp();
    }

    _forceCheck = false;
    final info = await ref.watch(proxyRepositoryProvider).getCurrentIpInfo(cancelToken).getOrElse((err) {
      loggy.warning("error getting proxy ip info", err, StackTrace.current);
      // throw err; //hiddify: remove exception to be logged
      throw const UnknownIp();
    }).run();

    timer = Timer(const Duration(seconds: 10), () {
      loggy.debug("entering idle mode");
      _idle = true;
      ref.invalidateSelf();
    });

    return info;
  }

  bool _idle = false;
  bool _forceCheck = false;

  Future<void> refresh() async {
    if (state.isLoading) return;
    loggy.debug("refreshing");
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    _forceCheck = true;
    ref.invalidateSelf();
  }
}

@Riverpod(keepAlive: true)
class ActiveProxyNotifier extends _$ActiveProxyNotifier with AppLogger {
  @override
  Stream<OutboundInfo> build() {
    // ref.disposeDelay(const Duration(seconds: 20));
    final serviceRunning = ref.watch(serviceRunningProvider);
    // The core is set up again when the app comes back from the background, on
    // a new gRPC channel. The stream below lives on the old one, so it has to be
    // opened again; serviceRunning stays true throughout and would not do it.
    ref.watch(coreRestartSignalProvider);
    if (serviceRunning != _lastServiceRunning) {
      _lastServiceRunning = serviceRunning;
      _wasConnectionValid = false;
      _resubscribeDelay = _minResubscribeDelay;
      _resetFailoverState();
    }
    if (!serviceRunning) {
      return Stream.error(const ServiceNotRunning());
    }
    Timer? resubscribe;
    ref.onDispose(() {
      resubscribe?.cancel();
      _stuckConnectingTimer?.cancel();
      _stuckConnectingTimer = null;
    });
    var received = 0;
    return _proxyRepo
        .watchActiveProxies()
        // A failed stream used to become an empty outbound with no delay, which the
        // connection button shows as a yellow "connecting" that never clears. The
        // tunnel itself is fine, so the last known outbound stays and the stream is
        // opened again below.
        .where((event) => event.isRight())
        .map((event) => event.getOrElse((l) => List<OutboundGroup>.empty()))
        // A group the core has not filled yet arrives with no items; reading
        // .first there killed the whole active-proxy stream with a
        // StateError and left the home page without a ping for good.
        .map((event) => event.firstOrNull?.items.firstOrNull ?? OutboundInfo())
        .doOnData((info) {
          // The first event is the core service's cached list, sent even when
          // the call fails; only a later one shows the stream really works.
          if (++received > 1) _resubscribeDelay = _minResubscribeDelay;
          _handleConnectionHaptic(info.urlTestDelay);
          // Leave the stream callback before touching other providers / await.
          Future.microtask(() => _maybeFailover(info));
        })
        .doOnDone(() {
          // gRPC ends the stream when its connection drops, e.g. once iOS suspends
          // the app or the Mac sleeps. Nothing else would ever open it again.
          // While it keeps failing the wait doubles, so a core that stays
          // unreachable is not retried, and logged as an error, every 2 seconds.
          loggy.debug("active proxy stream ended, resubscribing in $_resubscribeDelay");
          resubscribe = Timer(_resubscribeDelay, ref.invalidateSelf);
          final doubled = _resubscribeDelay * 2;
          _resubscribeDelay = doubled < _maxResubscribeDelay ? doubled : _maxResubscribeDelay;
        });
  }

  ProxyRepository get _proxyRepo => ref.read(proxyRepositoryProvider);

  /// Whether the tunnel currently has a valid ping. Tracked so haptics fire only
  /// on real transitions (connect / timeout / recover), not on every ping update.
  bool _wasConnectionValid = false;
  bool? _lastServiceRunning;

  static const _minResubscribeDelay = Duration(seconds: 2);
  static const _maxResubscribeDelay = Duration(seconds: 30);
  Duration _resubscribeDelay = _minResubscribeDelay;

  /// Consecutive timed-out pings before switching. One blip is ignored.
  static const _minInvalidBeforeFailover = 2;
  static const _failoverCooldown = Duration(seconds: 20);
  static const _urlTestCooldown = Duration(seconds: 45);
  /// "Connecting…" with delay 0 forever (common on Balancer) must escape too.
  static const _stuckConnecting = Duration(seconds: 12);

  int _invalidStreak = 0;
  bool _failoverInFlight = false;
  DateTime? _lastFailoverAt;
  DateTime? _lastUrlTestAt;
  DateTime? _connectingSince;
  Timer? _stuckConnectingTimer;
  OutboundInfo? _lastActiveForFailover;
  final Set<String> _triedTags = {};

  void _resetFailoverState() {
    _invalidStreak = 0;
    _failoverInFlight = false;
    _lastFailoverAt = null;
    _lastUrlTestAt = null;
    _connectingSince = null;
    _stuckConnectingTimer?.cancel();
    _stuckConnectingTimer = null;
    _lastActiveForFailover = null;
    _triedTags.clear();
  }

  /// Balancer/QUIC often stay on delay 0 with no further stream events; keep a
  /// timer so a failed/cooldown escape still retries instead of sticking forever.
  void _armStuckConnectingTimer([Duration wait = _stuckConnecting]) {
    _stuckConnectingTimer?.cancel();
    final delay = wait <= Duration.zero ? const Duration(milliseconds: 50) : wait;
    _stuckConnectingTimer = Timer(delay, () {
      _stuckConnectingTimer = null;
      final latest = _lastActiveForFailover;
      if (latest != null) unawaited(_maybeFailover(latest));
    });
  }

  void _handleConnectionHaptic(int urlTestDelay) {
    final isValid = ConnectionConst.isValidDelay(urlTestDelay);
    if (isValid == _wasConnectionValid) return;
    _wasConnectionValid = isValid;
    final haptic = ref.read(hapticServiceProvider.notifier);
    if (isValid) {
      // connected successfully, or recovered after a timeout
      haptic.heavyImpact();
    } else {
      // still connected but the ping timed out → medium then heavy
      haptic.mediumImpact();
      Future.delayed(const Duration(milliseconds: 150), haptic.heavyImpact);
    }
  }

  Future<void> _maybeFailover(OutboundInfo active) async {
    if (!ref.read(Preferences.autoFailoverProxy)) return;
    if (_lastServiceRunning != true) return;

    final delay = active.urlTestDelay;
    if (ConnectionConst.isValidDelay(delay)) {
      _invalidStreak = 0;
      _connectingSince = null;
      _stuckConnectingTimer?.cancel();
      _stuckConnectingTimer = null;
      _triedTags.clear();
      return;
    }

    _lastActiveForFailover = active;
    var stuckConnecting = false;
    if (delay == 0) {
      // Fresh connect: wait a bit for the first ping. Balancer/QUIC can sit on
      // delay 0 forever ("Connecting…"), so escape after [_stuckConnecting].
      // The active-proxy stream may not emit again while stuck, so arm a timer.
      _connectingSince ??= DateTime.now();
      final waited = DateTime.now().difference(_connectingSince!);
      if (waited < _stuckConnecting) {
        if (_stuckConnectingTimer == null) {
          _armStuckConnectingTimer(_stuckConnecting - waited);
        }
        return;
      }
      _stuckConnectingTimer?.cancel();
      _stuckConnectingTimer = null;
      stuckConnecting = true;
      _invalidStreak = _minInvalidBeforeFailover;
    } else {
      _connectingSince = null;
      _stuckConnectingTimer?.cancel();
      _stuckConnectingTimer = null;
      _invalidStreak++;
      if (_invalidStreak < _minInvalidBeforeFailover) return;
    }

    if (_failoverInFlight) {
      if (stuckConnecting) _armStuckConnectingTimer(_failoverCooldown);
      return;
    }
    final last = _lastFailoverAt;
    if (last != null) {
      final since = DateTime.now().difference(last);
      if (since < _failoverCooldown) {
        if (stuckConnecting) _armStuckConnectingTimer(_failoverCooldown - since);
        return;
      }
    }

    _failoverInFlight = true;
    var switched = false;
    try {
      switched = await _runFailover(active, allowUnmeasured: stuckConnecting);
    } catch (e, st) {
      loggy.warning("proxy failover failed", e, st);
    } finally {
      _failoverInFlight = false;
    }
    // Still delay 0 and no stream push: re-arm so we do not stick on Connecting.
    if (!switched && stuckConnecting && _lastServiceRunning == true) {
      _armStuckConnectingTimer(_failoverCooldown);
    }
  }

  /// Returns true when a replacement outbound was selected.
  Future<bool> _runFailover(OutboundInfo active, {required bool allowUnmeasured}) async {
    final group = await _resolveProxyGroup();
    if (group == null || group.tag.isEmpty) {
      loggy.debug("failover: no proxy group available yet");
      return false;
    }

    final leaf = ProxyFailover.leafTag(active);
    final exclude = <String>{
      leaf,
      active.tag,
      group.selected,
      ..._triedTags,
    };

    final candidates = allowUnmeasured
        ? ProxyFailover.escapeCandidates(group, excludeTags: exclude)
        : ProxyFailover.rankedCandidates(group, excludeTags: exclude);
    if (candidates.isEmpty) {
      await _urlTestForFailover(group.tag);
      return false;
    }

    final next = candidates.first;
    loggy.info(
      "failover: [$leaf] ${allowUnmeasured ? 'stuck connecting' : 'timed out'} → [${next.tag}] (${next.urlTestDelay}ms)",
    );
    final selected = await _proxyRepo
        .selectProxy(group.tag, next.tag)
        .map((_) => true)
        .getOrElse((err) {
          loggy.warning("failover select failed", err);
          return false;
        })
        .run();
    if (!selected) return false;

    _triedTags.add(leaf);
    _triedTags.add(next.tag);
    _lastFailoverAt = DateTime.now();
    _invalidStreak = 0;
    _connectingSince = null;

    final t = ref.read(translationsProvider).requireValue;
    ref
        .read(inAppNotificationControllerProvider)
        .showInfoToast(t.pages.proxies.autoFailoverSwitched(name: ProxyFailover.displayName(next)));
    return true;
  }

  Future<OutboundGroup?> _resolveProxyGroup() async {
    final cached = ref.read(proxiesOverviewNotifierProvider).valueOrNull;
    if (cached != null && cached.tag.isNotEmpty) return cached;

    try {
      final group = await _proxyRepo
          .watchProxies()
          .map((event) => event.fold((_) => null, (g) => g))
          .firstWhere((group) => group != null && group.tag.isNotEmpty)
          .timeout(const Duration(seconds: 2));
      return group;
    } catch (_) {
      return null;
    }
  }

  Future<void> _urlTestForFailover(String groupTag) async {
    final last = _lastUrlTestAt;
    if (last != null && DateTime.now().difference(last) < _urlTestCooldown) {
      loggy.debug("failover: url test skipped (cooldown)");
      return;
    }
    _lastUrlTestAt = DateTime.now();
    // Clear tries so a fresh test can promote previously skipped tags.
    _triedTags.clear();
    loggy.info("failover: no live candidate, url-testing [$groupTag]");
    final result = await _proxyRepo.urlTest(groupTag).run();
    if (result.isLeft()) loggy.warning("failover url test failed", result);
  }

  final _urlTestThrottler = Throttler(const Duration(seconds: 1));

  Future<void> urlTest(String? groupTag_) async {
    final groupTag = groupTag_ ?? "";
    // The callback is handed to the throttler, which calls it without awaiting
    // it, so a throw here used to become an unhandled async error instead of
    // reaching the caller. The failure is logged and the button does nothing.
    _urlTestThrottler(() async {
      if (state case AsyncData()) {
        await ref.read(hapticServiceProvider.notifier).lightImpact();
        final result = await ref.read(proxyRepositoryProvider).urlTest(groupTag).run();
        if (result.isLeft()) loggy.warning("error testing group", result);
      }
    });
  }
}
