import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hiddify/features/app_update/model/release_notes_markdown.dart';
import 'package:hiddify/utils/utils.dart';

/// Renders GitHub release notes as markdown inside the update dialog.
///
/// Owns formatting ([releaseNotesToMarkdown]) and presentation so
/// [NewVersionDialog] stays a thin shell shared by startup and About.
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView(this.raw, {super.key, this.maxHeight = 220});

  final String? raw;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final markdown = releaseNotesToMarkdown(raw);
    if (markdown == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        child: MarkdownBody(
          data: markdown,
          shrinkWrap: true,
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            p: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            h1: theme.textTheme.titleSmall,
            h2: theme.textTheme.titleSmall,
            h3: theme.textTheme.labelLarge,
            listBullet: theme.textTheme.bodySmall,
            a: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
          onTapLink: (text, href, title) {
            if (href == null || href.isEmpty) return;
            UriUtils.tryLaunch(Uri.parse(href));
          },
        ),
      ),
    );
  }
}
