import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/utils/platform_utils.dart';

/// Turns what the core says when a start fails into the failure the UI shows.
///
/// The core reports these as plain text inside a gRPC error, worded by the Go
/// runtime and the OS, so they are English on every system language. Matching
/// them is the only way to tell "you need to elevate" apart from "this config
/// is broken" — the two look identical in the status the core reports.
///
/// The old check lived inline in the start path and matched one exact Windows
/// string. That missed Linux and macOS (`operation not permitted`), Windows'
/// ERROR_PRIVILEGE_NOT_HELD (`A required privilege is not held by the client.`)
/// and every message that wrapped the text differently, so the "Missing
/// privilege — relaunch as administrator" dialog the app ships in 11 languages
/// was never shown to anyone. See issues #2276, #2224 and the rest.
class CoreStartFailure {
  const CoreStartFailure._();

  /// Fragments that mean the TUN adapter could not be created because the
  /// process lacks the right.
  static const privilegeMarkers = <String>[
    // Windows, when the TUN device is opened without elevation.
    "Access is denied",
    // Windows, ERROR_PRIVILEGE_NOT_HELD (1314). Worded differently from the above.
    "privilege is not held by the client",
    // Linux and macOS.
    "operation not permitted",
    // Linux, when the TUN device node is missing for the user.
    "permission denied",
  ];

  /// Another VPN (or a stale adapter) already owns the address the core gives
  /// its TUN.
  static const addressInUseMarkers = <String>[
    "The object already exists",
    "set ipv4 address: file exists",
    "Address already in use",
  ];

  /// Classifies a start failure reported through a gRPC error message.
  ///
  /// On desktop a missing privilege is actionable — relaunch elevated — so it
  /// gets its own failure with its own text. On mobile the same wording means
  /// the VPN permission was refused, which is a different dialog.
  static ConnectionFailure fromMessage(String message) {
    if (privilegeMarkers.any(message.contains)) {
      return PlatformUtils.isDesktop ? const ConnectionFailure.missingPrivilege() : const ConnectionFailure.missingVpnPermission();
    }
    if (addressInUseMarkers.any(message.contains)) {
      return const ConnectionFailure.tunAddressInUse();
    }
    return ConnectionFailure.unexpected(message);
  }
}
