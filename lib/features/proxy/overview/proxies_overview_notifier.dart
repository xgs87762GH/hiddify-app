import 'dart:async';
import 'dart:math';

import 'package:dartx/dartx.dart';

import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';

import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:rxdart/rxdart.dart';

part 'proxies_overview_notifier.g.dart';

enum ProxiesSort {
  unsorted,
  name,
  delay,
  usage;

  String present(TranslationsEn t) => switch (this) {
    ProxiesSort.unsorted => t.pages.proxies.sortOptions.unsorted,
    ProxiesSort.name => t.pages.proxies.sortOptions.name,
    ProxiesSort.delay => t.pages.proxies.sortOptions.delay,
    ProxiesSort.usage => t.pages.proxies.sortOptions.usage,
  };
}

@Riverpod(keepAlive: true)
class ProxiesSortNotifier extends _$ProxiesSortNotifier with AppLogger {
  late final _pref = PreferencesEntry(
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    key: "proxies_sort_mode",
    defaultValue: ProxiesSort.delay,
    mapFrom: ProxiesSort.values.byName,
    mapTo: (value) => value.name,
  );

  @override
  ProxiesSort build() {
    final sortBy = _pref.read();
    loggy.info("sort proxies by: [${sortBy.name}]");
    return sortBy;
  }

  Future<void> update(ProxiesSort value) {
    state = value;
    return _pref.write(value);
  }
}

@riverpod
class ProxiesOverviewNotifier extends _$ProxiesOverviewNotifier with AppLogger {
  @override
  Stream<OutboundGroup?> build() {
    ref.disposeDelay(const Duration(seconds: 15));
    final serviceRunning = ref.watch(serviceRunningProvider);
    // Set up again when the app comes back from the background, on a new gRPC
    // channel; the stream below lives on the old one.
    ref.watch(coreRestartSignalProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    // Reopening the stream also runs build, and that must not drop the pin.
    if (serviceRunning != _lastServiceRunning || sortBy != _lastSortBy) {
      _lastServiceRunning = serviceRunning;
      _lastSortBy = sortBy;
      _pinned = null;
      _resubscribeDelay = _minResubscribeDelay;
    }
    if (!serviceRunning) {
      return Stream.error(const ServiceNotRunning());
    }
    Timer? resubscribe;
    ref.onDispose(() => resubscribe?.cancel());
    // yield* ref
    //     .watch(proxyRepositoryProvider)
    //     .watchProxies()
    //     .throttleTime(
    //       const Duration(milliseconds: 100),
    //       leading: false,
    //       trailing: true,
    //     )
    //     .map(
    //       (event) => event.getOrElse(
    //         (err) {
    //           loggy.warning("error receiving proxies", err);
    //           throw err;
    //         },
    //       ),
    //     )
    //     .asyncMap((proxies) async => _sortOutbounds(proxies, sortBy));
    return ref
        .watch(proxyRepositoryProvider)
        .watchProxies()
        // A failed stream used to become an error the page showed as "Unexpected error"
        // for as long as it stayed open, while the tunnel itself kept working. The failure
        // is logged, the last list stays on screen, and the stream is opened again below.
        .where(
          (event) => event.fold((err) {
            // The stream is closed on every resume, and gRPC reports the dead
            // channel as a failure. That is not the list failing to load, so it
            // is not worth a warning; anything else is.
            final cause = err is ProxyUnexpectedFailure ? err.error : null;
            if (cause != null && HiddifyCoreService.isConnectionTerminated(cause)) {
              loggy.debug("proxies stream ended with the channel: $cause");
            } else {
              loggy.warning("error receiving proxies", err);
            }
            return false;
          }, (_) => true),
        )
        .map((event) => event.getOrElse((_) => null))
        // A null payload would blank the page, contradicting the promise above
        // that the last list stays on screen, so it is dropped here.
        .where((proxies) => proxies != null)
        .doOnData((_) => _resubscribeDelay = _minResubscribeDelay)
        .doOnDone(() {
          // gRPC ends the stream when its connection drops, e.g. once iOS suspends the app.
          // While reopening keeps failing the wait doubles, as for the active proxy.
          loggy.debug("proxies stream ended, resubscribing in $_resubscribeDelay");
          resubscribe = Timer(_resubscribeDelay, ref.invalidateSelf);
          final doubled = _resubscribeDelay * 2;
          _resubscribeDelay = doubled < _maxResubscribeDelay ? doubled : _maxResubscribeDelay;
        })
        .asyncMap((proxies) async => await _sortOutbounds(proxies, sortBy));
  }

  bool? _lastServiceRunning;
  ProxiesSort? _lastSortBy;

  static const _minResubscribeDelay = Duration(seconds: 2);
  static const _maxResubscribeDelay = Duration(seconds: 30);
  Duration _resubscribeDelay = _minResubscribeDelay;

  // Future<List<OutboundGroup>> _sortOutbounds(
  //   List<OutboundGroup> proxies,
  //   ProxiesSort sortBy,
  // ) async {
  //   final groupWithSelected = {
  //     for (final o in proxies) o.tag: o.selected,
  //   };
  //   final sortedProxies = <OutboundGroup>[];
  //   for (final group in proxies) {
  //     final sortedItems = switch (sortBy) {
  //       ProxiesSort.name => group.items.sortedWith((a, b) {
  //           if (a.isGroup && !b.isGroup) return -1;
  //           if (!a.isGroup && b.isGroup) return 1;
  //           return a.tag.compareTo(b.tag);
  //         }),
  //       ProxiesSort.delay => group.items.sortedWith((a, b) {
  //           if (a.isGroup && !b.isGroup) return -1;
  //           if (!a.isGroup && b.isGroup) return 1;

  //           final ai = a.urlTestDelay;
  //           final bi = b.urlTestDelay;
  //           if (ai == 0 && bi == 0) return -1;
  //           if (ai == 0 && bi > 0) return 1;
  //           if (ai > 0 && bi == 0) return -1;
  //           return ai.compareTo(bi);
  //         }),
  //       ProxiesSort.unsorted => group.items,
  //     };
  //     final items = <OutboundInfo>[];
  //     for (final item in sortedItems) {
  //       // if (groupWithSelected.keys.contains(item.tag)) {
  //       //   items.add(item.copyWith(selectedTag: groupWithSelected[item.tag]));
  //       // } else {
  //       items.add(item);
  //       // }
  //     }
  //     group.items.clear();
  //     group.items.addAll(items);
  //     sortedProxies.add(group);
  //   }
  //   return sortedProxies;
  // }

  /// The proxy picked on this page and the row it was in. Cleared by a new connection or sort.
  ({String tag, int index})? _pinned;

  Future<OutboundGroup?> _sortOutbounds(OutboundGroup? proxies, ProxiesSort sortBy) async {
    if (proxies == null) return null;

    final sortedItems = switch (sortBy) {
      ProxiesSort.name => proxies.items.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return a.tag.compareTo(b.tag);
      }),
      ProxiesSort.delay => proxies.items.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;

        final ai = a.urlTestDelay;
        final bi = b.urlTestDelay;
        // A ping of 0 means "not measured yet", so those go last. Returning
        // -1 when both are 0 broke the comparator's contract (a < b and b < a
        // at once) and made the order of the untested proxies arbitrary — the
        // whole list shuffled on every event until the first test finished.
        if (ai == 0 && bi == 0) return a.tag.compareTo(b.tag);
        if (ai == 0) return 1;
        if (bi == 0) return -1;
        return ai.compareTo(bi);
      }),
      ProxiesSort.unsorted => proxies.items,
      ProxiesSort.usage => proxies.items.sortedWith((a, b) {
        if (a.isGroup && !b.isGroup) return -1;
        if (!a.isGroup && b.isGroup) return 1;
        return (b.upload + b.download).compareTo(a.upload + a.download);
      }),
    };
    // a copy: sortedItems reads proxies.items, which is cleared below
    final items = sortedItems.toList();
    // The proxy the user picked stays in the row they tapped, and the rest sorts around it. A new
    // ping used to move it, often to the end of the list, right after the tap.
    if (_pinned case (:final tag, :final index) when proxies.selected == tag) {
      final picked = items.indexWhere((item) => item.tag == tag);
      if (picked != -1) items.insert(min(index, items.length - 1), items.removeAt(picked));
    }
    proxies.items.clear();
    proxies.items.addAll(items);
    return proxies;
  }

  // Future<void> changeProxy(String groupTag, String outboundTag) async {
  //   loggy.debug(
  //     "changing proxy, group: [$groupTag] - outbound: [$outboundTag]",
  //   );
  //   if (state case AsyncData(value: final outbounds)) {
  //     await ref.read(hapticServiceProvider.notifier).lightImpact();
  //     await ref.read(proxyRepositoryProvider).selectProxy(groupTag, outboundTag).getOrElse((err) {
  //       loggy.warning("error selecting outbound", err);
  //       throw err;
  //     }).run();
  //     final outboundg = outbounds.where((e) => e.tag == groupTag).firstOrNull;
  //     if (outboundg != null) {
  //       final newselected = outboundg.items.where((e) => e.tag == outboundTag).firstOrNull;
  //       if (newselected != null) {
  //         newselected.isSelected = true;
  //         outboundg.selected = newselected;
  //       }
  //     }
  //     state = AsyncData(
  //       [...outbounds],
  //     ).copyWithPrevious(state);
  //   }
  // }

  Future<void> changeProxy(String groupTag, String outboundTag) async {
    loggy.debug("changing proxy, group: [$groupTag] - outbound: [$outboundTag]");
    if (!state.hasValue) return;
    final outbounds = state.value!;
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    final selected = await ref
        .read(proxyRepositoryProvider)
        .selectProxy(groupTag, outboundTag)
        .map((_) => true)
        .getOrElse((err) {
          loggy.warning("error selecting outbound", err);
          // thrown from a tap, the error reached no one and the tap seemed ignored
          final t = ref.read(translationsProvider).requireValue;
          ref.read(inAppNotificationControllerProvider).showErrorToast(t.pages.proxies.switchFailed);
          return false;
        })
        .run();
    if (!selected) return;
    final row = outbounds.items.indexWhere((e) => e.tag == outboundTag);
    if (row != -1) _pinned = (tag: outboundTag, index: row);
    // The old code below is what the new one replaces; it is kept here only in
    // this comment so the reason is on the page: mutating `outbounds` in place
    // and handing the same object back to `state` is a no-op, because Riverpod
    // compares the new state with the previous one and a protobuf message is
    // equal to itself. The tap then moved the highlight only when the core
    // happened to send the next list.
    if (outbounds.items.any((e) => e.tag == outboundTag)) {
      final updated = outbounds.deepCopy();
      for (final item in updated.items) {
        item.isSelected = item.tag == outboundTag;
      }
      updated.selected = outboundTag;
      state = AsyncValue.data(updated);
    }
  }

  Future<void> urlTest(String groupTag) async {
    loggy.debug("testing group: [$groupTag]");
    if (state case AsyncData()) {
      await ref.read(hapticServiceProvider.notifier).lightImpact();
      // Thrown from a tap, the error reached no one: the page has no handler
      // for it and the test simply seemed to do nothing.
      final result = await ref.read(proxyRepositoryProvider).urlTest(groupTag).run();
      if (result.isLeft()) loggy.warning("error testing group", result);
    }
  }
}
