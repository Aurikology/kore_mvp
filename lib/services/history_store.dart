import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../session/reset_record.dart';

/// Reset history on disk, as a single JSON file.
///
/// Uses `dart:io` and environment variables directly rather than
/// `path_provider`. That is not stubbornness: path_provider is a plugin, and
/// the project's zero-plugin property is what lets the Windows build work
/// without Developer Mode and lets the DSP and session tests run on the host
/// VM with no Flutter binding (see the note in pubspec.yaml).
///
/// Every method is failure-tolerant. Losing a reset log is a cosmetic problem;
/// taking the dashboard down over a read-only directory is not.
class HistoryStore {
  /// Keeps the file bounded. At the documented usage of a few resets a day
  /// this is years of history, and it caps a pathological writer.
  static const int maxRecords = 500;

  final File file;

  HistoryStore(this.file);

  /// `%APPDATA%\KORE\history.json` on Windows, `~/.kore/history.json`
  /// elsewhere, falling back to the system temp directory when neither
  /// variable is set (some CI and service contexts).
  factory HistoryStore.defaultLocation() {
    final env = Platform.environment;
    final base = Platform.isWindows
        ? (env['APPDATA'] ?? env['LOCALAPPDATA'])
        : env['HOME'];

    final dir = base == null || base.isEmpty
        ? Directory('${Directory.systemTemp.path}/kore')
        : Directory(Platform.isWindows ? '$base/KORE' : '$base/.kore');

    return HistoryStore(File('${dir.path}/history.json'));
  }

  Future<ResetHistory> load() async {
    try {
      if (!await file.exists()) return ResetHistory.empty;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return ResetHistory.empty;

      final records = <ResetRecord>[];
      for (final entry in decoded) {
        final r = ResetRecord.tryFromJson(entry);
        if (r != null) records.add(r);
      }
      records.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      return ResetHistory(records);
    } catch (e) {
      // A corrupt file is not worth a red screen. The next append rewrites it.
      debugPrint('KORE: could not read reset history ($e); starting empty');
      return ResetHistory.empty;
    }
  }

  /// Appends [record] and returns the history as written. On failure the
  /// in-memory history still advances, so the UI stays truthful about the
  /// session the user just did even if the disk write lost.
  Future<ResetHistory> append(ResetHistory current, ResetRecord record) async {
    final updated = current.add(record);
    final trimmed = updated.records.length > maxRecords
        ? ResetHistory(
            updated.records.sublist(updated.records.length - maxRecords))
        : updated;

    try {
      await file.parent.create(recursive: true);
      final json = jsonEncode([for (final r in trimmed.records) r.toJson()]);

      // Write beside the target and move into place, so an interrupted write
      // cannot leave a half-file where the real history was.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // Windows refuses a rename onto an existing file. Copy-then-delete is
        // not atomic, but load() already tolerates a partial file.
        await tmp.copy(file.path);
        await tmp.delete();
      }
    } catch (e) {
      debugPrint('KORE: could not persist reset history ($e)');
    }

    return trimmed;
  }
}
