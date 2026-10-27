import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

/// Picks a replacement outbound when the active one has timed out.
///
/// Kept free of Riverpod so the ranking rules can be unit-tested without the core.
abstract final class ProxyFailover {
  static const groupTags = {'auto', 'select'};
  static const nonProxyTags = {'direct', 'block', 'dns', 'reject'};

  /// Tags / types that usually need UDP and fail first on filtered broadband.
  static bool looksQuic(OutboundInfo item) {
    final hay = '${item.tag} ${item.type} ${item.tagDisplay}'.toLowerCase();
    return hay.contains('quic') ||
        hay.contains('hysteria') ||
        hay.contains('tuic') ||
        hay.contains('h3') ||
        hay.contains('wireguard');
  }

  /// Leaf tag currently carrying traffic (urltest's pick, or the selected outbound).
  static String leafTag(OutboundInfo active) {
    if (active.groupSelectedTag.isNotEmpty) return active.groupSelectedTag;
    return active.tag;
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
      if (item.isGroup) continue;
      final tag = item.tag;
      if (tag.isEmpty) continue;
      final lower = tag.toLowerCase();
      if (exclude.contains(lower)) continue;
      if (groupTags.contains(lower) || nonProxyTags.contains(lower)) continue;
      if (!ConnectionConst.isValidDelay(item.urlTestDelay)) continue;
      live.add(item);
    }

    live.sort((a, b) {
      final aquic = looksQuic(a) ? 1 : 0;
      final bquic = looksQuic(b) ? 1 : 0;
      if (aquic != bquic) return aquic.compareTo(bquic);
      final delay = a.urlTestDelay.compareTo(b.urlTestDelay);
      if (delay != 0) return delay;
      return a.tag.compareTo(b.tag);
    });
    return live;
  }

  static String displayName(OutboundInfo item) =>
      item.tagDisplay.isNotEmpty ? item.tagDisplay : item.tag;
}
