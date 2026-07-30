import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// TESTBED ONLY. Local experiment recording for the evaluation chapter.
///
/// While an experiment is active every [log] record is appended to a
/// per-experiment JSONL file (`exp_<id>.jsonl`) under the app documents dir.
/// Files leave the device only on the experimenter's explicit action from the
/// testbed screen — the share sheet, or a manual upload to the trace server
/// ([uploadExperimentFiles]). There is no automatic upload, no prompt, and no
/// pseudonymization: records carry real pubkey hex so runs correlate across
/// devices offline. When no experiment is active, [log] is a no-op.
class ExperimentRecorder {
  static const _subdir = 'trace';

  String? _experimentId;
  String? get experimentId => _experimentId;

  /// Whether an experiment is recording — the gate instrumentation checks
  /// before composing records. Zero cost in normal operation.
  bool get active => _experimentId != null;

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_subdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async => File('${(await _dir()).path}/$name');

  static String _expFileName(String id) => 'exp_$id.jsonl';

  /// Normalize a user-entered experiment id to a safe filename fragment.
  static String sanitizeExperimentId(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return cleaned.isEmpty ? 'exp' : cleaned;
  }

  /// Append one record to the active experiment file. No-op when inactive;
  /// never throws.
  Future<void> log(Map<String, dynamic> record) async {
    final expId = _experimentId;
    if (expId == null) return;
    try {
      final exp = await _file(_expFileName(expId));
      await exp.writeAsString('${jsonEncode(record)}\n',
          mode: FileMode.append, flush: false);
    } catch (e) {
      debugPrint('[exp] log failed: $e');
    }
  }

  /// Begin (or resume — appends to an existing file of the same id) an
  /// experiment recording. Marks the boundary with an `expStart` marker.
  Future<void> startExperiment(String id) async {
    final clean = sanitizeExperimentId(id);
    _experimentId = clean;
    await log({
      'type': 'marker',
      'event': 'expStart',
      'exp': clean,
      't': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Stop the experiment recording, marking the boundary with `expStop`.
  Future<void> stopExperiment() async {
    if (_experimentId == null) return;
    await log({
      'type': 'marker',
      'event': 'expStop',
      'exp': _experimentId,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    _experimentId = null;
  }

  /// Free-form ground-truth annotation (distance step, direction, note),
  /// stamped by the experimenter from the testbed screen.
  Future<void> logMarker(String label) => log({
        'type': 'marker',
        'event': 'note',
        'label': label,
        'exp': _experimentId,
        't': DateTime.now().millisecondsSinceEpoch,
      });

  /// Paths of all experiment files currently on disk (any id, sorted).
  Future<List<String>> experimentFilePaths() async {
    final dir = await _dir();
    final out = <String>[];
    await for (final f in dir.list()) {
      if (f is File && f.uri.pathSegments.last.startsWith('exp_')) {
        out.add(f.path);
      }
    }
    out.sort();
    return out;
  }

  /// Size in bytes of the active experiment's file (0 when absent/inactive).
  Future<int> experimentFileSize() async {
    final id = _experimentId;
    if (id == null) return 0;
    final f = await _file(_expFileName(id));
    return await f.exists() ? await f.length() : 0;
  }

  /// Upload every experiment file to the trace server (`POST /v1/traces`,
  /// gzip + bearer auth — the same endpoint the server already exposes).
  /// One envelope per file; `uploadId` is derived from the file name and
  /// length so a retry of an unchanged file is idempotent server-side.
  /// [deviceId] labels the uploads (use this device's pubkey hex so the
  /// experiment correlates across devices). Files are kept after upload —
  /// deleting them stays an explicit [clearExperimentFiles].
  /// Returns a short user-facing status line.
  Future<String> uploadExperimentFiles({
    required String url,
    required String token,
    required String deviceId,
  }) async {
    final paths = await experimentFilePaths();
    if (paths.isEmpty) return 'No experiment files to upload';
    var uploaded = 0;
    var failed = 0;
    for (final path in paths) {
      try {
        final file = File(path);
        final name = file.uri.pathSegments.last;
        final length = await file.length();
        final records = <Map<String, dynamic>>[];
        for (final line in (await file.readAsString()).split('\n')) {
          if (line.trim().isEmpty) continue;
          try {
            records.add(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            // skip a corrupt line rather than failing the file
          }
        }
        if (records.isEmpty) continue;
        final envelope = {
          'uploadId': '$name:$length',
          'deviceId': deviceId,
          'schemaVersion': 1,
          'generatedAt': DateTime.now().toUtc().toIso8601String(),
          'platform': Platform.isIOS ? 'ios' : 'android',
          'experiment': name,
          'consent': true,
          'records': records,
        };
        final body = gzip.encode(utf8.encode(jsonEncode(envelope)));
        final resp = await http
            .post(
              Uri.parse('${_normalizeBase(url)}/v1/traces'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Content-Encoding': 'gzip',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          uploaded++;
        } else {
          failed++;
          debugPrint('[exp] upload of $name rejected: HTTP ${resp.statusCode}');
        }
      } catch (e) {
        failed++;
        debugPrint('[exp] upload failed for $path: $e');
      }
    }
    return failed == 0
        ? 'Uploaded $uploaded experiment file(s)'
        : 'Uploaded $uploaded, $failed failed — kept locally for retry';
  }

  static String _normalizeBase(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Delete all experiment files (after a successful share/upload).
  Future<void> clearExperimentFiles() async {
    for (final path in await experimentFilePaths()) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
