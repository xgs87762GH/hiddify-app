import 'dart:io';

String? _path;

bool get isLogFileOpen => _path != null;

/// The file is capped so a long-lived install cannot fill the disk.
///
/// app.log only takes errors, but a core that keeps failing on every reconnect
/// can produce thousands of them a day, and the file was never rotated: the one
/// on the machine this was written for had grown past 100 KB of pure repetition
/// and the engine's own log next to it was 45 MB. When the file passes the cap
/// it is moved to `<name>.1` — one generation, replaced each time — so the
/// newest errors survive and the size stays bounded.
const _maxBytes = 1024 * 1024; // 1 MiB

/// Checked rather than measured on every line: a `stat` per record would cost
/// more than the write. 64 KiB of error lines is a lot of lines.
const _checkEveryBytes = 64 * 1024;
int _writtenSinceCheck = 0;

/// Opens by creating the file and proving it is writable, so a bad path is
/// known now rather than silently swallowed at the first error worth recording.
void openLogFile(String path) {
  try {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('', mode: FileMode.append);
    _path = path;
    _writtenSinceCheck = 0;
    _rotateIfNeeded(file);
  } catch (_) {
    _path = null;
  }
}

/// Written straight through, no batching.
///
/// Only errors reach this file, and they are rare, so a syscall each is cheap
/// and nothing can be sitting in memory when the crash that follows takes the
/// app down.
void writeLogLine(String line) {
  final path = _path;
  if (path == null) return;

  try {
    final file = File(path);
    file.writeAsStringSync('$line\n', mode: FileMode.append);
    _writtenSinceCheck += line.length + 1;
    if (_writtenSinceCheck >= _checkEveryBytes) {
      _writtenSinceCheck = 0;
      _rotateIfNeeded(file);
    }
  } catch (_) {
    // A log file that cannot be written must never take the app down.
  }
}

/// Moves the file aside once it is past the cap.
///
/// Failure here is not worth reporting either: a log that cannot be rotated is
/// still a log that can be written.
void _rotateIfNeeded(File file) {
  try {
    if (!file.existsSync() || file.lengthSync() <= _maxBytes) return;
    final rotated = File('${file.path}.1');
    if (rotated.existsSync()) rotated.deleteSync();
    file.renameSync(rotated.path);
    // Keep writing to the same path, now a fresh file.
    File(file.path).writeAsStringSync('', mode: FileMode.append);
  } catch (_) {
    // see above
  }
}

Future<void> closeLogFile() async {
  _path = null;
}

/// Writes [lines] to [path] in one go, replacing whatever was there. Used by
/// the logs page to export the in-memory history, which is a different file.
Future<void> writeLinesToFile(String path, Iterable<String> lines) async {
  await File(path).writeAsString(lines.join('\n'));
}
