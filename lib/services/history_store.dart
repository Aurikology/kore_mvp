import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../dsp/load_profile.dart';
import '../session/kore_history.dart';
import '../session/reset_record.dart';

/// KORE's history on disk, as a single JSON file.
///
/// Uses `dart:io` and environment variables directly rather than
/// `path_provider`. That is not stubbornness: path_provider is a plugin, and
/// the project's zero-plugin property is what lets the Windows build work
/// without Developer Mode and lets the DSP and session tests run on the host
/// VM with no Flutter binding (see the note in pubspec.yaml).
///
/// The file carries three things ([KoreHistory]): the reset log, the personal
/// load profile, and the daily rollup. All three are bounded - 500 records,
/// 180 days, and a profile of fixed size - so the file has a ceiling that does
/// not depend on how long the app has been installed.
///
/// Every method is failure-tolerant. Losing a reset log is a cosmetic problem;
/// taking the dashboard down over a read-only directory is not.
class HistoryStore {
  /// Keeps the reset log bounded. At the documented usage of a few resets a
  /// day this is years of history, and it caps a pathological writer.
  static const int maxRecords = 500;

  final File file;

  HistoryStore(this.file);

  /// `%APPDATA%\KORE\history.json` on Windows, the app's private files
  /// directory on Android, `~/.kore/history.json` elsewhere, falling back to
  /// the system temp directory when none of those can be worked out (some CI
  /// and service contexts).
  factory HistoryStore.defaultLocation() {
    final env = Platform.environment;

    if (Platform.isAndroid) {
      return HistoryStore(
          File('${androidBase(Directory.systemTemp.path).path}/history.json'));
    }

    final base = Platform.isWindows
        ? (env['APPDATA'] ?? env['LOCALAPPDATA'])
        : env['HOME'];

    final dir = base == null || base.isEmpty
        ? Directory('${Directory.systemTemp.path}/kore')
        : Directory(Platform.isWindows ? '$base/KORE' : '$base/.kore');

    return HistoryStore(File('${dir.path}/history.json'));
  }

  /// Where a KORE history belongs on Android, worked out from [tmpPath].
  ///
  /// This is the one place the zero-plugin property costs something real.
  /// Everywhere else `dart:io` and an environment variable are enough;
  /// Android sets no `HOME`, so the general path above lands on
  /// `Directory.systemTemp` - which is the app's **cache** directory, and
  /// Android deletes cache directories under storage pressure without asking.
  /// A user's streak, baseline and fortnight of trend would evaporate the
  /// first time their phone filled up, and nothing would say why.
  ///
  /// `path_provider` is the ordinary answer and is a plugin, which the project
  /// refuses for reasons written up in `pubspec.yaml` - it is what keeps the
  /// whole test suite running on the host VM with no Flutter binding. The
  /// files directory is the cache directory's sibling, so it can be derived
  /// rather than asked for.
  ///
  /// Deliberately conservative: if the path is not the shape this expects, it
  /// falls through to the old behaviour rather than guessing. Losing history
  /// to a cleared cache is bad; writing it somewhere outside the app's own
  /// sandbox would be worse.
  @visibleForTesting
  static Directory androidBase(String tmpPath) {
    const cache = '/cache';

    if (tmpPath.endsWith(cache)) {
      final root = tmpPath.substring(0, tmpPath.length - cache.length);
      return Directory('$root/files/KORE');
    }

    return Directory('$tmpPath/kore');
  }

  /// The whole document: resets, the personal load profile, and the daily
  /// rollup. Reads a v1 file (a bare record array) as well as a v2 one.
  Future<KoreHistory> loadDocument() async {
    try {
      if (!await file.exists()) return KoreHistory.empty;
      return KoreHistory.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      // A corrupt file is not worth a red screen. The next write rewrites it.
      debugPrint('KORE: could not read history ($e); starting empty');
      return KoreHistory.empty;
    }
  }

  /// Just the resets. Kept as the narrow read the dashboard actually wants.
  Future<ResetHistory> load() async => (await loadDocument()).resets;

  /// Appends [record] and returns the history as written. On failure the
  /// in-memory history still advances, so the UI stays truthful about the
  /// session the user just did even if the disk write lost.
  ///
  /// [current] is the caller's live view of the resets and replaces what is on
  /// disk. Everything the caller did not pass is re-read and carried forward -
  /// see [_writeMerged].
  Future<ResetHistory> append(
    ResetHistory current,
    ResetRecord record, {
    LoadProfile? profile,
    DailyLoadLog? days,
  }) async {
    final updated = current.add(record);
    final trimmed = updated.records.length > maxRecords
        ? ResetHistory(
            updated.records.sublist(updated.records.length - maxRecords))
        : updated;

    await _writeMerged(resets: trimmed, profile: profile, days: days);
    return trimmed;
  }

  /// Persists the personal baseline, thresholds, and today's rollup without
  /// touching the reset log. This is the write that happens when a session
  /// calibrates but the user never takes a reset - which is most sessions, and
  /// exactly the ones the profile needs to learn from.
  Future<void> saveState({
    required LoadProfile profile,
    required DailyLoadLog days,
  }) =>
      _writeMerged(profile: profile, days: days);

  /// Records that the first-run flow has been completed, carrying everything
  /// else forward untouched.
  ///
  /// Written the moment the user leaves the pairing screen rather than at the
  /// end of their first session: the flow is finished when they have seen it,
  /// and a crash before the first reset is not a reason to show them the
  /// welcome screen again.
  Future<void> markOnboarded(DateTime at) =>
      _writeMerged(app: AppState(onboardingCompletedAt: at));

  /// Whether the first-run flow has been completed. A file that cannot be read
  /// reads as "no", which costs one avoidable screen and never skips the claim
  /// boundary.
  Future<bool> hasOnboarded() async => (await loadDocument()).app.hasOnboarded;

  /// Read-modify-write. The store re-reads before every write rather than
  /// holding the document in memory: a session only ever owns some of it, and
  /// writing back a whole document assembled from a partial view is how one
  /// half silently erases the other.
  Future<void> _writeMerged({
    ResetHistory? resets,
    LoadProfile? profile,
    DailyLoadLog? days,
    AppState? app,
  }) async {
    final merged = (await loadDocument())
        .copyWith(resets: resets, profile: profile, days: days, app: app);

    try {
      await file.parent.create(recursive: true);
      final json = jsonEncode(merged.toJson());

      // Write beside the target and move into place, so an interrupted write
      // cannot leave a half-file where the real history was.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        // Windows refuses a rename onto an existing file. Copy-then-delete is
        // not atomic, but loadDocument() already tolerates a partial file.
        await tmp.copy(file.path);
        await tmp.delete();
      }
    } catch (e) {
      debugPrint('KORE: could not persist history ($e)');
    }
  }
}
