import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key});

  final String currentVersion;
  final RemoteVersionEntity newVersion;

  /// Flattens the GitHub release body (markdown) into a short readable summary.
  String? _summary() {
    final raw = newVersion.releaseNotes;
    if (raw == null) return null;
    final lines = raw
        .split('\n')
        .map((line) {
          var l = line.trim();
          l = l.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
          l = l.replaceAll(RegExp(r'\*\*|__|`'), '');
          if (RegExp(r'^[-*+]\s+').hasMatch(l)) {
            l = '• ${l.replaceFirst(RegExp(r'^[-*+]\s+'), '')}';
          }
          return l;
        })
        .where((l) => l.isNotEmpty)
        .where((l) => !l.startsWith('<!--'))
        .where((l) => !l.startsWith('All changes from'))
        .take(12)
        .join('\n');
    return lines.isEmpty ? null : lines;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final summary = _summary();

    return AlertDialog(
      title: Text(t.dialogs.newVersion.title),
      content: Column(
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
          if (summary != null) ...[
            const Gap(12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Text(summary, style: theme.textTheme.bodySmall?.copyWith(height: 1.4)),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            // Remember this version so the startup prompt stops nagging about it;
            // a later release (a different version) is still announced.
            await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
            if (context.mounted) context.pop();
          },
          child: Text(t.common.later),
        ),
        TextButton(
          onPressed: () async {
            await UriUtils.tryLaunch(Uri.parse(newVersion.url));
          },
          child: Text(t.dialogs.newVersion.updateNow),
        ),
      ],
    );
  }
}
