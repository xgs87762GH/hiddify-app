import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/model/release_notes_markdown.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/widget/release_notes_view.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Shared by the startup prompt and About → Check for update.
///
/// Presentation only: formatting lives in [releaseNotesToMarkdown], timing
/// rules in [AppUpdatePrompt], persistence in [AppUpdateNotifier].
class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key});

  final String currentVersion;
  final RemoteVersionEntity newVersion;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final hasNotes = releaseNotesToMarkdown(newVersion.releaseNotes) != null;

    return AlertDialog(
      title: Text(t.dialogs.newVersion.title),
      content: ConstrainedBox(
        constraints: AlertDialogConst.boxConstraints,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.dialogs.newVersion.msg),
            const Gap(8),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: "${t.dialogs.newVersion.currentVersion} ", style: theme.textTheme.bodySmall),
                  TextSpan(text: currentVersion, style: theme.textTheme.labelMedium),
                ],
              ),
            ),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: "${t.dialogs.newVersion.newVersion} ", style: theme.textTheme.bodySmall),
                  TextSpan(text: newVersion.presentVersion, style: theme.textTheme.labelMedium),
                ],
              ),
            ),
            if (hasNotes) ...[
              const Gap(12),
              ReleaseNotesView(newVersion.releaseNotes),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            // Close first so the UI never feels stuck, then persist. A write
            // failure only means the prompt may return next launch.
            Navigator.of(context).pop();
            try {
              await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
              loggy.info("dismissed update prompt for [${newVersion.version}]");
            } catch (e, st) {
              loggy.warning("failed to save ignored release [${newVersion.version}]", e, st);
            }
          },
          child: Text(t.common.later),
        ),
        TextButton(
          onPressed: () async {
            loggy.debug("opening release page for [${newVersion.version}]");
            await UriUtils.tryLaunch(Uri.parse(newVersion.url));
          },
          child: Text(t.dialogs.newVersion.updateNow),
        ),
      ],
    );
  }
}
