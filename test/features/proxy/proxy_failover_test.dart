import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/proxy/active/proxy_failover.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

OutboundInfo _item({
  required String tag,
  String type = 'vless',
  int delay = 100,
  bool isGroup = false,
  String tagDisplay = '',
  String groupSelectedTag = '',
}) {
  return OutboundInfo(
    tag: tag,
    type: type,
    urlTestDelay: delay,
    isGroup: isGroup,
    tagDisplay: tagDisplay,
    groupSelectedTag: groupSelectedTag,
  );
}

void main() {
  group('ProxyFailover.looksQuic', () {
    test('detects quic-ish tags and types', () {
      expect(ProxyFailover.looksQuic(_item(tag: 'VLESS Reality')), isFalse);
      expect(ProxyFailover.looksQuic(_item(tag: 'Hysteria2 QUIC HC', type: 'hysteria2')), isTrue);
      expect(ProxyFailover.looksQuic(_item(tag: 'node', type: 'tuic')), isTrue);
      expect(ProxyFailover.looksQuic(_item(tag: 'xhttp-h3')), isTrue);
      expect(ProxyFailover.looksQuic(_item(tag: 'wg-home', type: 'wireguard')), isFalse);
    });
  });

  group('ProxyFailover.leafTag', () {
    test('prefers groupSelectedTag when set', () {
      expect(
        ProxyFailover.leafTag(_item(tag: 'Auto', groupSelectedTag: 'dead-quic')),
        'dead-quic',
      );
      expect(ProxyFailover.leafTag(_item(tag: 'manual-node')), 'manual-node');
    });
  });

  group('ProxyFailover.rankedCandidates', () {
    test('skips groups, dead delays, and excluded tags; prefers non-quic', () {
      final group = OutboundGroup(
        tag: 'Select',
        selected: 'Auto',
        items: [
          _item(tag: 'Auto', isGroup: true, delay: 0),
          _item(tag: 'dead-quic', type: 'hysteria2', delay: ConnectionConst.maxDelay),
          _item(tag: 'quic-ok', type: 'tuic', delay: 80),
          _item(tag: 'tcp-slow', delay: 200),
          _item(tag: 'tcp-fast', delay: 50),
          _item(tag: 'untested', delay: 0),
          _item(tag: 'Direct', type: 'direct', delay: 10),
        ],
      );

      final ranked = ProxyFailover.rankedCandidates(
        group,
        excludeTags: {'dead-quic', 'Auto'},
      );

      expect(ranked.map((e) => e.tag).toList(), ['tcp-fast', 'tcp-slow', 'quic-ok']);
    });

    test('returns empty when nothing live remains', () {
      final group = OutboundGroup(
        tag: 'Select',
        items: [
          _item(tag: 'only', delay: ConnectionConst.maxDelay),
        ],
      );
      expect(
        ProxyFailover.rankedCandidates(group, excludeTags: {'only'}),
        isEmpty,
      );
    });
  });

  group('ProxyFailover.escapeCandidates', () {
    test('escapes balancer by picking unmeasured non-quic leaf', () {
      final group = OutboundGroup(
        tag: 'Select',
        selected: 'Balancer',
        items: [
          _item(tag: 'Balancer', type: 'balancer', isGroup: true, delay: 0),
          _item(tag: 'quic-node', type: 'hysteria2', delay: 0),
          _item(tag: 'reality-a', type: 'vless', delay: 0),
          _item(tag: 'reality-b', type: 'vless', delay: 0),
        ],
      );

      final escaped = ProxyFailover.escapeCandidates(
        group,
        excludeTags: {'Balancer'},
      );

      expect(escaped.map((e) => e.tag).toList(), ['reality-a', 'reality-b']);
    });

    test('prefers live delays over unmeasured when both exist', () {
      final group = OutboundGroup(
        tag: 'Select',
        items: [
          _item(tag: 'unmeasured-tcp', delay: 0),
          _item(tag: 'live-tcp', delay: 40),
          _item(tag: 'live-quic', type: 'tuic', delay: 20),
        ],
      );

      expect(
        ProxyFailover.escapeCandidates(group, excludeTags: {}).map((e) => e.tag).toList(),
        ['live-tcp', 'live-quic'],
      );
    });
  });

  group('ProxyFailover.displayName', () {
    test('uses tagDisplay when present', () {
      expect(
        ProxyFailover.displayName(_item(tag: 'raw', tagDisplay: 'Pretty')),
        'Pretty',
      );
      expect(ProxyFailover.displayName(_item(tag: 'raw')), 'raw');
    });
  });
}
