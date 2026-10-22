import 'dart:io';

import 'package:path/path.dart' as p;

class LogPathResolver {
  const LogPathResolver(this._workingDir);

  final Directory _workingDir;

  Directory get directory => _workingDir;

  /// The engine's own log. It writes into `data/`, not the working directory
  /// root — the root box.log the app used to point at was always empty.
  File coreFile() {
    return File(p.join(directory.path, "data", "box.log"));
  }

  /// Trims the engine's log down to its last [keepBytes] when it is over
  /// [maxBytes].
  ///
  /// The engine appends to box.log for the whole life of an install and never
  /// rotates it, so the file grows without bound — 45 MB on the machine this
  /// was written for, nearly all of it repeated connection errors. The engine
  /// holds the file open, so it can only be trimmed while it is not running:
  /// this is called during bootstrap, before the core is set up.
  ///
  /// Only the tail is kept, which is what a bug report needs. A trim that fails
  /// is not an error worth surfacing — the log simply stays as large as it was.
  void trimCoreLog({int maxBytes = 5 * 1024 * 1024, int keepBytes = 1024 * 1024}) {
    try {
      final file = coreFile();
      if (!file.existsSync() || file.lengthSync() <= maxBytes) return;

      final source = file.openSync();
      final List<int> tail;
      try {
        source.setPositionSync(file.lengthSync() - keepBytes);
        tail = source.readSync(keepBytes);
      } finally {
        source.closeSync();
      }

      // The cut lands mid-line, so the first line is a fragment; drop it rather
      // than hand a reader a truncated error message.
      final firstBreak = tail.indexOf(0x0A);
      final kept = firstBreak == -1 ? tail : tail.sublist(firstBreak + 1);

      final replacement = File("${file.path}.trim");
      replacement.writeAsBytesSync(kept, flush: true);
      file.deleteSync();
      replacement.renameSync(file.path);
    } catch (_) {
      // see above
    }
  }

  /// The engine's last crash, or null when it has not crashed.
  ///
  /// Go's runtime writes its fatal traceback to `CrashReport-.log`
  /// (`debug.SetCrashOutput`). On the next launch the engine moves that file
  /// into `crash_reports/<UTC timestamp>/go.log` and deletes the original, so
  /// crashes pile up as one folder each. The newest archived one is what is
  /// wanted; the live file only still exists when the app has not restarted
  /// since the crash.
  File? coreCrashFile() {
    final archive = Directory(p.join(directory.path, "crash_reports"));
    if (archive.existsSync()) {
      final reports = archive.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final report in reports.reversed) {
        final log = File(p.join(report.path, "go.log"));
        if (log.existsSync()) return log;
      }
    }

    final live = File(p.join(directory.path, "CrashReport-.log"));
    return live.existsSync() && live.lengthSync() > 0 ? live : null;
  }

  File appFile() {
    return File(p.join(directory.path, "app.log"));
  }

  /// Where the in-memory history is written when the user shares it. A
  /// separate name, so it never collides with the app.log the sink is still
  /// writing to on desktop.
  File appExportFile() {
    return File(p.join(directory.path, "app-logs.txt"));
  }
}
