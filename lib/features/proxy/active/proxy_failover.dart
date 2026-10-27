import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// Picks a replacement outbound when the active one has timed out or never connects.
///
/// Kept free of Riverpod so the ranking rules can be unit-tested without the core.
abstract final class ProxyFailover {
  static const groupTags = {'auto', 'select'};
  static const nonProxyTags = {'direct', 'block', 'dns', 'reject'};
  static const groupTypes = {'balancer', 'urltest', 'selector'};

  /// Tags / types that usually need UDP and fail first on filtered broadband.
  static bool looksQuic(OutboundInfo item) {
    final hay = '${item.tag} ${item.type} ${item.tagDisplay}'.toLowerCase();
    return hay.contains('quic') ||
        hay.contains('hysteria') ||
        hay.contains('tuic') ||
        hay.contains('h3') ||
        hay.contains('wireguard');
  }

  static bool isGroupOutbound(OutboundInfo item) {
    if (item.isGroup) return true;
    return groupTypes.contains(item.type.toLowerCase());
  }

  /// Leaf tag currently carrying traffic (urltest/balancer pick, or the selected outbound).
  static String leafTag(OutboundInfo active) {
    if (active.groupSelectedTag.isNotEmpty) return active.groupSelectedTag;
    return active.tag;
  }

  static bool _skippable(OutboundInfo item, Set<String> exclude) {
    if (isGroupOutbound(item)) return true;
    final tag = item.tag;
    if (tag.isEmpty) return true;
    final lower = tag.toLowerCase();
    if (exclude.contains(lower)) return true;
    if (groupTags.contains(lower) || nonProxyTags.contains(lower)) return true;
    return false;
  }

  static void _sortPreferTcpThenDelay(List<OutboundInfo> items) {
    items.sort((a, b) {
      final aquic = looksQuic(a) ? 1 : 0;
      final bquic = looksQuic(b) ? 1 : 0;
      if (aquic != bquic) return aquic.compareTo(bquic);
      final aLive = ConnectionConst.isValidDelay(a.urlTestDelay);
      final bLive = ConnectionConst.isValidDelay(b.urlTestDelay);
      if (aLive != bLive) return aLive ? -1 : 1;
      if (aLive && bLive) {
        final delay = a.urlTestDelay.compareTo(b.urlTestDelay);
        if (delay != 0) return delay;
      }
      return a.tag.compareTo(b.tag);
    });
  }

  /// Live, non-group outbounds ranked for failover: TCP-like first, then by delay.
  static List<OutboundInfo> rankedCandidates(
    OutboundGroup group, {
    required Set<String> excludeTags,
  }) {
    final exclude = {
      for (final tag in excludeTags)
        if (tag.isNotEmpty) tag.toLowerCase(),
    };

    final live = <OutboundInfo>[];
    for (final item in group.items) {
      if (_skippable(item, exclude)) continue;
      if (!ConnectionConst.isValidDelay(item.urlTestDelay)) continue;
      live.add(item);
    }
    _sortPreferTcpThenDelay(live);
    return live;
  }

  /// When ping never arrives (stuck "Connecting…"), escape Balancer/QUIC even
  /// if sibling delays are still 0 — prefer non-QUIC leaf outbounds.
  static List<OutboundInfo> escapeCandidates(
    OutboundGroup group, {
    required Set<String> excludeTags,
  }) {
    final live = rankedCandidates(group, excludeTags: excludeTags);
    if (live.isNotEmpty) return live;

    final exclude = {
      for (final tag in excludeTags)
        if (tag.isNotEmpty) tag.toLowerCase(),
    };

    final optimistic = <OutboundInfo>[];
    for (final item in group.items) {
      if (_skippable(item, exclude)) continue;
      if (looksQuic(item)) continue;
      optimistic.add(item);
    }
    _sortPreferTcpThenDelay(optimistic);
    if (optimistic.isNotEmpty) return optimistic;

    // Last resort: any non-group leaf, including QUIC.
    final any = <OutboundInfo>[];
    for (final item in group.items) {
      if (_skippable(item, exclude)) continue;
      any.add(item);
    }
    _sortPreferTcpThenDelay(any);
    return any;
  }

  static String displayName(OutboundInfo item) =>
      item.tagDisplay.isNotEmpty ? item.tagDisplay : item.tag;
}
