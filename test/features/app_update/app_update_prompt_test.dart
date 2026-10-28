import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/app_update_prompt.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';

RemoteVersionEntity _v(String version) => RemoteVersionEntity(
      version: version,
      buildNumber: '1',
      releaseTag: 'v$version',
      preRelease: false,
      url: 'https://example.com',
      publishedAt: DateTime.utc(2026, 1, 1),
      flavor: Environment.prod,
    );

void main() {
  group('AppUpdatePrompt.shouldShowPassively', () {
    test('only Available', () {
      expect(AppUpdatePrompt.shouldShowPassively(AppUpdateState.available(_v('5.0.8'))), isTrue);
      expect(AppUpdatePrompt.shouldShowPassively(AppUpdateState.ignored(_v('5.0.8'))), isFalse);
      expect(AppUpdatePrompt.shouldShowPassively(const AppUpdateState.checking()), isFalse);
      expect(AppUpdatePrompt.shouldShowPassively(const AppUpdateState.notAvailable()), isFalse);
    });
  });

  group('AppUpdatePrompt.shouldShowAfterManualCheck', () {
    test('shows Available from a check', () {
      expect(
        AppUpdatePrompt.shouldShowAfterManualCheck(
          const AppUpdateState.checking(),
          AppUpdateState.available(_v('5.0.8')),
        ),
        isTrue,
      );
    });

    test('re-offers Ignored only when previous was Checking', () {
      expect(
        AppUpdatePrompt.shouldShowAfterManualCheck(
          const AppUpdateState.checking(),
          AppUpdateState.ignored(_v('5.0.8')),
        ),
        isTrue,
      );
      // "Later" path: Available → Ignored must NOT reopen.
      expect(
        AppUpdatePrompt.shouldShowAfterManualCheck(
          AppUpdateState.available(_v('5.0.8')),
          AppUpdateState.ignored(_v('5.0.8')),
        ),
        isFalse,
      );
    });

    test('ignores unrelated states', () {
      expect(
        AppUpdatePrompt.shouldShowAfterManualCheck(
          const AppUpdateState.checking(),
          AppUpdateState.error(const AppUpdateFailure.unexpected()),
        ),
        isFalse,
      );
    });
  });
}
