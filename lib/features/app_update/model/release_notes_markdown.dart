/// Converts a GitHub release body into markdown suitable for [MarkdownBody].
///
/// Upstream bodies mix HTML (badges, download tables), markdown, and a Persian
/// mirror of the English download section. This helper is deliberately pure
/// Dart so the dialog / About page / startup prompt share one path and so the
/// rules can be unit-tested without Flutter.
///
/// Returns `null` when nothing worth showing remains — callers should hide the
/// notes pane rather than render an empty box.
String? releaseNotesToMarkdown(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // Flatten HTML chrome; keep markdown headings / lists / links intact.
  final cleaned = trimmed
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<img\b[^>]*/?>', caseSensitive: false), '')
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|tr|li|h[1-6])>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'&[a-zA-Z0-9#]+;'), ' ');

  final lines = <String>[];
  for (final line in cleaned.split('\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    if (_isNoiseLine(l)) continue;
    lines.add(l);
  }

  if (lines.isEmpty) return null;

  final buffer = StringBuffer();
  for (final line in lines) {
    buffer.writeln(line);
  }
  final md = buffer.toString().trim();
  return md.isEmpty ? null : md;
}

bool _isNoiseLine(String line) {
  // Persian / Arabic blocks from the upstream bilingual template.
  if (RegExp(r'[\u0600-\u06FF]').hasMatch(line)) return true;

  // Strip markdown emphasis / table pipes so template leftovers still match.
  final plain = line
      .replaceAll(RegExp(r'[*_`#\[\]]'), ' ')
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .replaceAll('|', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (plain.isEmpty) return true;

  if (RegExp(r'^download based on', caseSensitive: false).hasMatch(plain)) {
    return true;
  }
  if (RegExp(r'^release downloads?$', caseSensitive: false).hasMatch(plain)) {
    return true;
  }
  // Bare OS / column labels left after the download table HTML is stripped.
  if (RegExp(
    r'^(android|windows|linux|macos(\s+v[\d.]+)?|os|download)$',
    caseSensitive: false,
  ).hasMatch(plain)) {
    return true;
  }
  // "| OS | Download |" header row after pipe stripping → "OS Download".
  if (RegExp(r'^os download$', caseSensitive: false).hasMatch(plain)) {
    return true;
  }
  // Template footer that only points at HISTORY.md — not useful in-dialog.
  if (RegExp(r'^list of all changes', caseSensitive: false).hasMatch(plain)) {
    return true;
  }
  if (RegExp(r'^changelog$', caseSensitive: false).hasMatch(plain)) {
    return true;
  }
  // Standalone URLs once badge/link chrome is gone.
  if (RegExp(r'^https?://\S+$').hasMatch(line)) return true;

  return false;
}
