import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/hiddifycore/core_start_failure.dart';

/// The core words a failed start itself, in English on every system language.
/// The app shipped a "Missing privilege — relaunch as administrator" dialog in
/// 11 languages that was never shown, because the only check matched one exact
/// Windows string (issue #2276 and the dozen duplicates linked from it).
void main() {
  test('Windows access denied is a missing privilege', () {
    final failure = CoreStartFailure.fromMessage(
      "start inbound/tun[tun-in]: configure tun interface: Access is denied.",
    );
    expect(failure, isA<MissingPrivilege>());
  });

  test('Windows ERROR_PRIVILEGE_NOT_HELD is a missing privilege', () {
    // Worded differently from the case above and contains neither "denied"
    // nor "not permitted", which is why it slipped through.
    final failure = CoreStartFailure.fromMessage(
      "start inbound/tun[tun-in]: configure tun interface: A required privilege is not held by the client.",
    );
    expect(failure, isA<MissingPrivilege>());
  });

  test('Linux operation not permitted is a missing privilege', () {
    final failure = CoreStartFailure.fromMessage(
      "manager start inbound/tun[tun-in]: configure tun interface: operation not permitted",
    );
    expect(failure, isA<MissingPrivilege>());
  });

  test('a taken TUN address is reported as such, not as a privilege problem', () {
    final failure = CoreStartFailure.fromMessage(
      "start inbound/tun[tun-in]: configure tun interface: set ipv4 address: The object already exists.",
    );
    expect(failure, isA<TunAddressInUse>());
  });

  test('anything else keeps the core text so it stays diagnosable', () {
    final failure = CoreStartFailure.fromMessage(
      ': outbounds[0: s1]: tls_fragment: json: unknown field "tls_fragment"',
    );
    expect(failure, isA<UnexpectedConnectionFailure>());
    expect(
      (failure as UnexpectedConnectionFailure).error.toString(),
      contains('tls_fragment'),
    );
  });
}
