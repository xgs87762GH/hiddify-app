import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_update/model/release_notes_markdown.dart';

void main() {
  group('releaseNotesToMarkdown', () {
    test('returns null for empty / null input', () {
      expect(releaseNotesToMarkdown(null), isNull);
      expect(releaseNotesToMarkdown(''), isNull);
      expect(releaseNotesToMarkdown('   \n  '), isNull);
    });

    test('drops the upstream download-table template as pure noise', () {
      const raw = '''
<div align="center">
<img src="https://img.shields.io/badge/x-y"/>
**Download based on your OS:**
**بر اساس سیستم عامل خود دانلود کنید:**
| OS | Download |
| Android |
| Windows |
| macOS (v10.15+) |
| Linux |
**List of all changes:** [ChangeLog](https://github.com/hiddify/hiddify-app/blob/main/HISTORY.md)
</div>
''';
      expect(releaseNotesToMarkdown(raw), isNull);
    });

    test('keeps real markdown changelog content and links', () {
      const raw = '''
## Fixes
- fix the Later button reopening the dialog
- harden quit disconnect

See [notes](https://example.com/notes) for detail.
''';
      final md = releaseNotesToMarkdown(raw)!;
      expect(md, contains('## Fixes'));
      expect(md, contains('fix the Later button'));
      expect(md, contains('[notes](https://example.com/notes)'));
      expect(md, isNot(contains('<div')));
    });

    test('strips HTML tags but preserves surrounding text', () {
      const raw = '<p>Hello <b>world</b></p><br/>Next line';
      final md = releaseNotesToMarkdown(raw)!;
      expect(md, contains('Hello world'));
      expect(md, contains('Next line'));
      expect(md, isNot(contains('<p>')));
    });
  });
}
