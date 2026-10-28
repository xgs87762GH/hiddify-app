import 'package:hiddify/features/app_update/notifier/app_update_state.dart';

/// Decides when the new-version dialog should appear.
///
/// Kept free of Flutter / Riverpod so startup ([App]) and About share the same
/// rules without importing each other.
abstract final class AppUpdatePrompt {
  /// Startup (and any passive check): only a freshly available release.
  ///
  /// Ignored versions stay quiet until the user asks again — that is what
  /// "Later" is for.
  static bool shouldShowPassively(AppUpdateState state) =>
      state is AppUpdateStateAvailable;

  /// About → "Check for update": show Available, and also re-offer a version
  /// the user previously dismissed *if this transition came from a check*.
  ///
  /// Matching on [AppUpdateStateChecking] → Ignored is what stops "Later"
  /// (Available → Ignored) from immediately reopening the dialog.
  static bool shouldShowAfterManualCheck(
    AppUpdateState? previous,
    AppUpdateState next,
  ) {
    if (next is AppUpdateStateAvailable) return true;
    if (next is AppUpdateStateIgnored && previous is AppUpdateStateChecking) {
      return true;
    }
    return false;
  }
}
