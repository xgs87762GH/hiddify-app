import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';

/// A profile saved by an older build carries the outbound-level
/// `tls_fragment` block in its JSON. The core rejects the whole config with
/// `json: unknown field "tls_fragment"`, so the profile cannot connect and the
/// app shows the core's text as a start failure. The key has to be rewritten
/// before the file reaches the core.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hiddify_profile_repair');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  File write(String name, Object json) {
    final file = File('${dir.path}/$name');
    file.writeAsStringSync(jsonEncode(json));
    return file;
  }

  test('the outbound-level block becomes the flag the core accepts', () {
    final file = write('profile.json', {
      'outbounds': [
        {
          'type': 'vless',
          'tag': 'a',
          'tls_fragment': {'enabled': true, 'size': '10-100', 'sleep': '50-200'},
          'tls': {'enabled': true},
        },
      ],
    });

    final changed = ProfileParser.repairLegacyFragmentKeys(file);

    expect(changed, isTrue);
    final outbound = ((jsonDecode(file.readAsStringSync()) as Map)['outbounds'] as List).first as Map;
    expect(outbound.containsKey('tls_fragment'), isFalse);
    expect((outbound['tls'] as Map)['fragment'], isTrue);
  });

  test('a disabled block is dropped and turns nothing on', () {
    final file = write('profile.json', {
      'outbounds': [
        {
          'type': 'vless',
          'tls_fragment': {'enabled': false, 'size': '10-100', 'sleep': '50-200'},
          'tls': {'enabled': true},
        },
      ],
    });

    ProfileParser.repairLegacyFragmentKeys(file);

    final outbound = ((jsonDecode(file.readAsStringSync()) as Map)['outbounds'] as List).first as Map;
    expect(outbound.containsKey('tls_fragment'), isFalse);
    expect((outbound['tls'] as Map).containsKey('fragment'), isFalse);
  });

  test('a block without a tls object still gets the flag', () {
    final file = write('profile.json', {
      'outbounds': [
        {
          'type': 'trojan',
          'tls_fragment': {'enabled': true},
        },
      ],
    });

    ProfileParser.repairLegacyFragmentKeys(file);

    final outbound = ((jsonDecode(file.readAsStringSync()) as Map)['outbounds'] as List).first as Map;
    expect(outbound.containsKey('tls_fragment'), isFalse);
    expect((outbound['tls'] as Map)['fragment'], isTrue);
  });

  test('the fragment key nested in tls is left alone', () {
    // Written by a current build through the editor; the core reads it.
    final file = write('profile.json', {
      'outbounds': [
        {
          'type': 'vless',
          'tls': {'enabled': true, 'fragment': true},
        },
      ],
    });
    final before = file.readAsStringSync();

    expect(ProfileParser.repairLegacyFragmentKeys(file), isFalse);
    expect(file.readAsStringSync(), before);
  });

  test('a profile with no such key is not rewritten at all', () {
    final file = write('profile.json', {
      'outbounds': [
        {'type': 'vless', 'tag': 'a'},
      ],
    });
    final before = file.readAsStringSync();

    expect(ProfileParser.repairLegacyFragmentKeys(file), isFalse);
    expect(file.readAsStringSync(), before);
  });

  test('a link list is left alone', () {
    final file = File('${dir.path}/links.txt')
      ..writeAsStringSync('vless://uuid@host:443?security=tls#name\n');

    expect(ProfileParser.repairLegacyFragmentKeys(file), isFalse);
    expect(file.readAsStringSync(), 'vless://uuid@host:443?security=tls#name\n');
  });
}
