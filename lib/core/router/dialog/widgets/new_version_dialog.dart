import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class NewVersionDialog extends HookConsumerWidget with PresLogger {
  NewVersionDialog(this.currentVersion, this.newVersion, {super.key});

  final String currentVersion;
  final RemoteVersionEntity newVersion;

  /// Flattens the GitHub release body (markdown + HTML) into a readable summary.
  String? _summary() {
    final raw = newVersion.releaseNotes;
    if (raw == null) return null;
    // Upstream release bodies mix HTML tags, shields.io images and Persian
    // blocks. Strip the markup before showing anything to the user.
    final cleaned = raw
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1] ?? '')
        .replaceAll(RegExp(r'&[a-zA-Z0-9#]+;'), ' ');
    final lines = cleaned
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
        // Persian/Arabic blocks from the upstream template add nothing here.
        .where((l) => !RegExp(r'[\u0600-\u06FF]').hasMatch(l))
        // Standalone URLs are noise once the link text is gone.
        .where((l) => !RegExp(r'^https?://\S+$').hasMatch(l))
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
            // Close first so the UI never feels stuck, then try to persist the
            // ignored version. If the write throws (storage unavailable, etc.)
            // the dialog is already gone and we only log it - the only
            // consequence is that the prompt reappears next launch, which is the
            // correct fallback for a genuine persistence failure.
            Navigator.of(context).pop();
            try {
              await ref.read(appUpdateNotifierProvider.notifier).ignoreRelease(newVersion);
            } catch (e, st) {
              loggy.warning("failed to save ignored release version", e, st);
            }
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
