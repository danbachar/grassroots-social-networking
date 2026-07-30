import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// TESTBED ONLY. Local experiment recording for the evaluation chapter.
///
/// While an experiment is active every [log] record is buffered in memory
/// and written to the per-experiment JSONL file (`exp_<id>.jsonl`, app
/// documents dir) in one append when the run stops — zero disk I/O inside
/// the measurement window, and an app kill mid-run loses the buffer.
/// Files leave the device only on the experimenter's explicit action from the
/// testbed screen — the share sheet, or a manual upload to the trace server
/// ([uploadExperimentFiles]). There is no automatic upload, no prompt, and no
/// pseudonymization: records carry real pubkey hex so runs correlate across
/// devices offline. When no experiment is active, [log] is a no-op.
class ExperimentRecorder {
  static const _subdir = 'trace';

  /// Optional fuel-gauge probe (raw BatteryManager readings, injected by the
  /// coordinator so this class stays platform-free and testable). While an
  /// experiment is active it is sampled every [powerSampleInterval] into
  /// `power` records. Readings taken while charging carry `charging: true`
  /// and are excluded from power analysis offline — a plugged-in phone
  /// reports charge current, not consumption.
  final Future<Map<String, dynamic>?> Function()? powerProbe;
  static const Duration powerSampleInterval = Duration(seconds: 10);
  Timer? _powerTimer;

  ExperimentRecorder({this.powerProbe});

  String? _experimentId;
  String? get experimentId => _experimentId;

  /// All records of the active experiment, held IN MEMORY and written to the
  /// file only when the run ends (or when the files are shared/uploaded
  /// mid-run). Rationale: no disk I/O inside the measurement window — the
  /// old per-call `writeAsString(mode: append)` fired hundreds of concurrent
  /// opens under load and silently dropped records (a 40-min soak lost ~a
  /// third of its `recv` records). Buffering is synchronous, ordered, and
  /// cannot drop; a 40-min run is well under 1 MB. The deliberate trade: an
  /// app kill mid-run loses the whole buffer.
  final List<String> _buffer = [];
  int _bufferedBytes = 0;

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

  /// Append one record to the active experiment's in-memory buffer. No-op
  /// when inactive; never throws. Purely synchronous — ordered, no I/O, no
  /// possibility of a dropped record.
  Future<void> log(Map<String, dynamic> record) async {
    if (_experimentId == null) return;
    try {
      final line = '${jsonEncode(record)}\n';
      _buffer.add(line);
      _bufferedBytes += line.length;
    } catch (e) {
      debugPrint('[exp] log failed: $e');
    }
  }

  /// Begin (or resume — the eventual write appends to an existing file of
  /// the same id) an experiment recording. Marks the boundary with an
  /// `expStart` marker.
  Future<void> startExperiment(String id) async {
    if (_experimentId != null) await _writeBufferToDisk();
    final clean = sanitizeExperimentId(id);
    _experimentId = clean;
    await log({
      'type': 'marker',
      'event': 'expStart',
      'exp': clean,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    final probe = powerProbe;
    if (probe != null) {
      Future<void> sample() async {
        try {
          final reading = await probe();
          if (reading == null || !active) return;
          await log({
            'type': 'power',
            't': DateTime.now().millisecondsSinceEpoch,
            ...reading,
          });
        } catch (e) {
          debugPrint('[exp] power probe failed: $e');
        }
      }

      unawaited(sample()); // baseline at the start boundary
      _powerTimer =
          Timer.periodic(powerSampleInterval, (_) => unawaited(sample()));
    }
  }

  /// Stop the experiment recording: mark the boundary with `expStop` and
  /// write the whole buffered run to disk in one append.
  Future<void> stopExperiment() async {
    if (_experimentId == null) return;
    _powerTimer?.cancel();
    _powerTimer = null;
    await log({
      'type': 'marker',
      'event': 'expStop',
      'exp': _experimentId,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    await _writeBufferToDisk();
    _experimentId = null;
  }

  /// Append everything buffered so far to the experiment file and clear the
  /// buffer. Called at stop, and before any read of the files (share/upload
  /// mid-run) so on-disk content is current.
  Future<void> _writeBufferToDisk() async {
    final expId = _experimentId;
    if (expId == null || _buffer.isEmpty) return;
    final lines = _buffer.join();
    _buffer.clear();
    _bufferedBytes = 0;
    try {
      final exp = await _file(_expFileName(expId));
      await exp.writeAsString(lines, mode: FileMode.append, flush: true);
    } catch (e) {
      debugPrint('[exp] buffer write failed: $e');
    }
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
    await _writeBufferToDisk(); // make the active file current before reading
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

  /// Size in bytes of the active experiment's data: what is already on disk
  /// plus the in-memory buffer (0 when inactive). Drives the UI counter
  /// without forcing a disk write.
  Future<int> experimentFileSize() async {
    final id = _experimentId;
    if (id == null) return 0;
    final f = await _file(_expFileName(id));
    final onDisk = await f.exists() ? await f.length() : 0;
    return onDisk + _bufferedBytes;
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
