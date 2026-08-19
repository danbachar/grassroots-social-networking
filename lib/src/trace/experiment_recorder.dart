import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// TESTBED ONLY. Local experiment recording for the evaluation chapter.
///
/// While an experiment is active every [log] record is buffered in memory and
/// written to the per-experiment JSONL file (`exp_<id>.jsonl`, app documents
/// dir) in ONE append when the run stops. No disk I/O happens inside a
/// measurement window — writing costs power and CPU, and the buffer's size
/// scales with traffic, so a periodic flush would land its largest write
/// inside the busiest condition and bias exactly what the power ladder
/// measures. The deliberate trade: an app kill mid-run loses the buffer.
/// Files leave the device only on the experimenter's explicit action from the
/// testbed screen — the share sheet, or a manual upload to the trace server
/// ([uploadExperimentFiles]). There is no automatic upload, no prompt, and no
/// pseudonymization: records carry real pubkey hex so runs correlate across
/// devices offline. When no experiment is active, [log] is a no-op.
/// Result of an upload sweep. [complete] is the load-bearing field: the
/// testbed screen goes green only when it is true, so "did every chunk land?"
/// is answerable at a glance instead of by re-pressing Upload and hoping.
class UploadOutcome {
  const UploadOutcome({
    required this.message,
    required this.complete,
    this.files = 0,
    this.chunks = 0,
  });

  /// Human-readable summary, shown in the snackbar.
  final String message;

  /// Every chunk of every file was accepted by the server.
  final bool complete;

  final int files;
  final int chunks;
}

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

  /// Records per upload POST. Bounds peak memory during upload to one batch
  /// rather than the whole file: a saturating run produces millions of
  /// records, and a single envelope of that size cannot be built on a phone.
  static const int uploadChunkRecords = 20000;
  Timer? _powerTimer;

  /// Optional buffer-occupancy probe (message-path buffer sizes, injected by
  /// the coordinator). Sampled on the same cadence as power into `buf`
  /// records — memory utilization over time, per buffer, plus this
  /// recorder's own in-memory backlog.
  final Map<String, dynamic> Function()? bufferProbe;

  /// Optional pre-stop hook, awaited at [stopExperiment] BEFORE the expStop
  /// marker: the coordinator drains sub-10s tails that would otherwise be
  /// lost (the wire ledger's last delta, a final power+buf sample).
  final Future<void> Function()? preStopFlush;

  /// Flush the buffer to disk each time the battery drops this many
  /// percentage points since the last flush.
  ///
  /// A discharge run has no clean stop — the phone hits its floor (or dies)
  /// while recording — and the buffer is memory-only, so without this the
  /// run that matters most loses everything. Pacing on STATE OF CHARGE
  /// rather than on a timer is what keeps this out of the measurement: the
  /// write rate follows the experiment's own progress (~20 small writes
  /// across a full discharge) instead of scaling with traffic, which is what
  /// made periodic flushing a confound in the first place.
  final int flushEverySocDrop;

  /// Fired once when a power sample reads at or below this state of charge.
  /// The field runner ends the run here.
  ///
  /// 5%, not 15%. A DISCHARGE measurement must stop at 15%, because Android's
  /// battery saver engages around there and everything past it is a different
  /// system. A MESH run has the opposite priority: a phone that stops is a
  /// hole in the topology for every remaining step -- one phone leaving at
  /// n=6 cost 26 of 60 steps their claimed mesh size. A degraded phone
  /// limping to the end under battery saver is worth more than a clean exit.
  ///
  /// The cost is explicit: samples below ~15% are taken under battery saver,
  /// so power and timing from that tail are not comparable with the rest of
  /// the run. The `battery-floor` marker still records where it stopped.
  final int batteryFloorPct;

  /// Set by the field runner for a discharge plan; called at most once per
  /// experiment, on the sample that first reaches [batteryFloorPct].
  void Function(int levelPct)? onBatteryFloor;

  int? _lastFlushLevel;
  bool _floorReported = false;

  /// Links that are ALREADY live when an experiment starts, logged right
  /// after the expStart marker. An event-replaying topology reconstruction
  /// cannot see an edge whose connect predates the recording; without this,
  /// phones that were sitting together connected draw at degree 0 while
  /// delivering everything.
  final List<Map<String, dynamic>> Function()? linkSnapshot;

  /// HTTP client for uploads. Injectable so the chunking can be tested —
  /// this is the path that once stranded a completed 5-hour run.
  final http.Client? httpClient;

  /// Fired after each uploaded chunk: the file, how many chunks have gone,
  /// and the fraction of that file's bytes consumed so far.
  ///
  /// Progress is measured in BYTES READ, not chunks, because the chunk total
  /// is not knowable in advance — the file is streamed, so how many 20k-record
  /// batches it holds is only discovered by reading it. The file's length is
  /// known up front, so the fraction is honest from the first chunk.
  void Function(String file, int chunksSent, double fraction)?
      onUploadProgress;

  ExperimentRecorder({
    this.powerProbe,
    this.bufferProbe,
    this.preStopFlush,
    this.flushEverySocDrop = 5,
    this.batteryFloorPct = 5,
    this.linkSnapshot,
    this.httpClient,
  });

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

  /// The id one step on from [id]: a trailing `-<n>` counts up, and an id
  /// without one gains `-2`. `line-1` -> `line-2`, `dial-8-n11` -> the
  /// digits there belong to the node count, not to a run counter, so it
  /// becomes `dial-8-n11-2` rather than silently claiming to be twelve nodes.
  static String nextExperimentId(String id) {
    final m = RegExp(r'^(.*)-(\d+)$').firstMatch(id);
    if (m == null) return '$id-2';
    return '${m.group(1)}-${int.parse(m.group(2)!) + 1}';
  }

  /// [id], or the first id after it whose file does not exist yet.
  ///
  /// A run must never write into a file another run already filled. The
  /// upload sends the whole file, so an id reused across runs re-sends every
  /// earlier run inside it, and the server ingests those records a second
  /// time under a new upload — silently doubling every count that is not
  /// keyed on something unique.
  Future<String> _freeExperimentId(String id) async {
    var candidate = id;
    // The fleet is eleven phones and a field day is tens of runs; the bound
    // is only here so a directory that cannot be written to ends the loop.
    for (var i = 0; i < 1000; i++) {
      if (!await (await _file(_expFileName(candidate))).exists()) {
        return candidate;
      }
      candidate = nextExperimentId(candidate);
    }
    return candidate;
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

  /// Begin an experiment recording under [id], or under the first id after it
  /// that has no file yet — a run never writes into another run's file.
  /// Marks the boundary with an
  /// `expStart` marker.
  Future<void> startExperiment(String id) async {
    if (_experimentId != null) await _writeBufferToDisk();
    // Starting without stopping first would otherwise leak the previous
    // run's timers and double-sample.
    _powerTimer?.cancel();
    _powerTimer = null;
    _bufTimer?.cancel();
    _bufTimer = null;
    _lastFlushLevel = null;
    _floorReported = false;
    final clean = await _freeExperimentId(sanitizeExperimentId(id));
    if (clean != sanitizeExperimentId(id)) {
      debugPrint('[exp] $id already has a file; recording as $clean');
    }
    _experimentId = clean;
    await log({
      'type': 'marker',
      'event': 'expStart',
      'exp': clean,
      't': DateTime.now().millisecondsSinceEpoch,
    });
    for (final r in linkSnapshot?.call() ?? const []) {
      await log(r);
    }
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
          await _onPowerReading(reading);
        } catch (e) {
          debugPrint('[exp] power probe failed: $e');
        }
      }

      unawaited(sample()); // baseline at the start boundary
      _powerTimer =
          Timer.periodic(powerSampleInterval, (_) => unawaited(sample()));
    }
    _sampleBuffers(); // baseline occupancy at the start boundary
    _bufTimer =
        Timer.periodic(powerSampleInterval, (_) => _sampleBuffers());
  }

  Timer? _bufTimer;

  /// Battery-paced flush, and the one-shot floor notification. Charging
  /// samples are ignored for the floor — a phone on a cable is not
  /// discharging toward it.
  Future<void> _onPowerReading(Map<String, dynamic> reading) async {
    final level = reading['levelPct'];
    if (level is! int) return;
    final charging = reading['charging'] == true;

    _lastFlushLevel ??= level;
    if (_lastFlushLevel! - level >= flushEverySocDrop) {
      _lastFlushLevel = level;
      await _writeBufferToDisk();
    }

    if (!charging && !_floorReported && level <= batteryFloorPct) {
      _floorReported = true;
      await log({
        'type': 'marker',
        'event': 'note',
        'label': 'battery-floor',
        'exp': _experimentId,
        't': DateTime.now().millisecondsSinceEpoch,
      });
      onBatteryFloor?.call(level);
    }
  }

  /// One `buf` record: every message-path buffer's occupancy right now.
  /// Purely synchronous reads of in-memory counters — no I/O, no async gap.
  void _sampleBuffers() {
    if (!active) return;
    final probe = bufferProbe;
    try {
      log({
        'type': 'buf',
        't': DateTime.now().millisecondsSinceEpoch,
        if (probe != null) ...probe(),
        // The recorder's own backlog: the one buffer the coordinator cannot
        // see. Grows with traffic for the whole run by design.
        'traceBufferedBytes': _bufferedBytes,
        'traceBufferedRecords': _buffer.length,
      });
    } catch (e) {
      debugPrint('[exp] buffer probe failed: $e');
    }
  }

  /// A final power reading, taken at the stop boundary so the run's tail is
  /// not cut off by the sampling period.
  Future<void> _finalPowerSample() async {
    final probe = powerProbe;
    if (probe == null) return;
    try {
      final reading = await probe();
      if (reading == null || !active) return;
      await log({
        'type': 'power',
        't': DateTime.now().millisecondsSinceEpoch,
        'final': true,
        ...reading,
      });
    } catch (e) {
      debugPrint('[exp] final power probe failed: $e');
    }
  }

  /// Stop the experiment recording: mark the boundary with `expStop` and
  /// write the whole buffered run to disk in one append.
  Future<void> stopExperiment() async {
    if (_experimentId == null) return;
    _powerTimer?.cancel();
    _powerTimer = null;
    _bufTimer?.cancel();
    _bufTimer = null;
    // Tail capture BEFORE the boundary marker: the wire ledger's last
    // sub-10s delta, one final power reading, one final buf snapshot. The
    // previous behaviour cancelled the timer and stopped — losing up to 10s
    // of gauge movement and traffic from the end of every run.
    try {
      await preStopFlush?.call();
    } catch (e) {
      debugPrint('[exp] preStopFlush failed: $e');
    }
    await _finalPowerSample();
    _sampleBuffers();
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
  /// Serializes appends. The periodic flush, a stop, and an upload-triggered
  /// flush can all fire close together; each takes its slice of the buffer
  /// SYNCHRONOUSLY (so the slices are disjoint and ordered) and then queues
  /// the append behind the previous one, so two writes can never interleave
  /// inside the file. A caller awaiting gets its own write's completion.
  Future<void> _writeChain = Future<void>.value();

  Future<void> _writeBufferToDisk() {
    final expId = _experimentId;
    if (expId == null || _buffer.isEmpty) return _writeChain;
    final lines = _buffer.join();
    _buffer.clear();
    _bufferedBytes = 0;
    _writeChain = _writeChain.then((_) async {
      try {
        final exp = await _file(_expFileName(expId));
        await exp.writeAsString(lines, mode: FileMode.append, flush: true);
      } catch (e) {
        debugPrint('[exp] buffer write failed: $e');
      }
    });
    return _writeChain;
  }

  /// Write everything buffered so far to disk. The field runner calls this
  /// at each step boundary — BETWEEN measurement windows, never inside one —
  /// so a run that is killed loses at most the step in progress. The
  /// state-of-charge flush covers long discharge runs; a short stepped run
  /// barely moves the battery, so nothing would be written until stop.
  Future<void> flush() => _writeBufferToDisk();

  @visibleForTesting
  Future<void> flushForTest() => _writeBufferToDisk();

  /// Take one power reading now, running the SoC-paced flush and floor check.
  /// Test seam: the periodic sampler is on a 10s timer.
  @visibleForTesting
  Future<void> forcePowerSampleForTest() async {
    final probe = powerProbe;
    if (probe == null || !active) return;
    final reading = await probe();
    if (reading == null) return;
    await log({
      'type': 'power',
      't': DateTime.now().millisecondsSinceEpoch,
      ...reading,
    });
    await _onPowerReading(reading);
  }

  /// Free-form ground-truth annotation (distance step, direction, note),
  /// stamped by the experimenter from the testbed screen. [extra] carries the
  /// step's own configuration — the fields the analyzer would otherwise have
  /// to infer from when links happen to appear.
  Future<void> logMarker(String label, {Map<String, Object?>? extra}) =>
      log({
        'type': 'marker',
        'event': 'note',
        'label': label,
        'exp': _experimentId,
        't': DateTime.now().millisecondsSinceEpoch,
        ...?extra,
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
  Future<UploadOutcome> uploadExperimentFiles({
    required String url,
    required String token,
    required String deviceId,
  }) async {
    final paths = await experimentFilePaths();
    if (paths.isEmpty) {
      return const UploadOutcome(
          message: 'No experiment files to upload', complete: false);
    }
    var uploaded = 0;
    var failed = 0;
    var chunksSent = 0;
    var skippedTotal = 0;

    for (final path in paths) {
      final file = File(path);
      final name = file.uri.pathSegments.last;
      final length = await file.length();
      final batch = <Map<String, dynamic>>[];
      var chunkIndex = 0;
      var skipped = 0;
      var ok = true;
      var bytesRead = 0;

      Future<bool> sendBatch() async {
        if (batch.isEmpty) return true;
        // uploadId is derived from (file, size, chunk) rather than from a
        // clock, so a retry re-derives the SAME ids and the server's
        // idempotency turns already-stored chunks into no-ops. That makes a
        // failed upload resumable by simply pressing Upload again.
        final sent = await _postChunk(
          url: url,
          token: token,
          deviceId: deviceId,
          name: name,
          uploadId: '$name:$length:$chunkIndex',
          records: batch,
        );
        batch.clear();
        chunkIndex++;
        if (sent) chunksSent++;
        onUploadProgress?.call(
            name, chunkIndex, length == 0 ? 1.0 : bytesRead / length);
        return sent;
      }

      try {
        // Stream the file. A saturating run produces hundreds of MB, and
        // reading it whole allocated it several times over (bytes, then a
        // UTF-16 String, then every record as a Map, then the re-encoded
        // envelope) — gigabytes of peak on a phone with a few hundred MB of
        // heap, which is why large uploads failed regardless of content.
        // Peak is now one batch.
        final lines = file
            .openRead()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter());
        await for (final line in lines) {
          // +1 for the newline the splitter consumed. Approximate for
          // multi-byte characters, which trace records barely contain.
          bytesRead += line.length + 1;
          if (line.trim().isEmpty) continue;
          try {
            batch.add(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            skipped++; // a torn line never fails the file
            continue;
          }
          if (batch.length >= uploadChunkRecords) {
            if (!await sendBatch()) {
              ok = false;
              break;
            }
          }
        }
        if (ok) ok = await sendBatch();
      } catch (e) {
        ok = false;
        debugPrint('[exp] upload failed for $path: $e');
      }

      skippedTotal += skipped;
      if (skipped > 0) {
        debugPrint('[exp] $name: skipped $skipped unparseable line(s)');
      }
      if (ok) {
        uploaded++;
      } else {
        failed++;
      }
    }

    final suffix = skippedTotal > 0 ? ', $skippedTotal line(s) skipped' : '';
    return UploadOutcome(
      message: failed == 0
          ? 'Uploaded $uploaded file(s) in $chunksSent chunk(s)$suffix'
          : 'Uploaded $uploaded, $failed failed — press Upload again to resume'
              '$suffix',
      // Green ONLY when every chunk of every file landed. Resuming a failed
      // sweep is safe — the same (file, length, chunk) re-derives the same
      // uploadId and the server no-ops it. What is NOT safe is re-pressing
      // after the file has GROWN: the new length yields new ids, idempotency
      // cannot fire, and the prefix is stored a second time. So the operator
      // needs to know "this finished" without pressing again to find out.
      complete: failed == 0,
      files: uploaded,
      chunks: chunksSent,
    );
  }

  /// POST one batch. Returns whether the server accepted (or already had) it.
  /// The handset model (`Build.MODEL` / the iOS machine name), or null where
  /// the platform channel is unavailable. An upload is never worth failing
  /// over a label, so every error here is swallowed.
  static Future<String?> _deviceModel() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return '${a.manufacturer} ${a.model}'.trim();
      }
      if (Platform.isIOS) {
        return (await info.iosInfo).utsname.machine;
      }
    } catch (_) {
      // No channel (unit tests, desktop) — the field is simply absent.
    }
    return null;
  }

  Future<bool> _postChunk({
    required String url,
    required String token,
    required String deviceId,
    required String name,
    required String uploadId,
    required List<Map<String, dynamic>> records,
  }) async {
    try {
      final envelope = {
        'uploadId': uploadId,
        'deviceId': deviceId,
        'schemaVersion': 1,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'platform': Platform.isIOS ? 'ios' : 'android',
        // The hardware behind the pubkey. A trace identifies a device by its
        // key, which is stable but says nothing about which handset it is,
        // and a run's nicknames are renumbered between campaigns so they do
        // not carry that across runs either. Naming the model here is what
        // lets a per-device result — a radio that never negotiates an MTU, a
        // leg that never reaches a session — be attributed to real hardware.
        if (await _deviceModel() case final String model) 'model': model,
        'experiment': name,
        'consent': true,
        'records': records,
      };
      final body = gzip.encode(utf8.encode(jsonEncode(envelope)));
      final client = httpClient;
      final post = client != null ? client.post : http.post;
      final resp = await post(
            Uri.parse('${_normalizeBase(url)}/v1/traces'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Content-Encoding': 'gzip',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
      debugPrint('[exp] chunk $uploadId rejected: HTTP ${resp.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[exp] chunk $uploadId failed: $e');
      return false;
    }
  }

  static String _normalizeBase(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Move an abandoned recording aside, so the next arm under the same id
  /// starts a clean file.
  ///
  /// Delete the recording of a run that aborted.
  ///
  /// [startExperiment] APPENDS to an existing file of the same id, so the dead
  /// run cannot simply be left in place: its step labels and re-minted message
  /// ids would interleave with the next arm's records in one upload, and every
  /// reader downstream would have to know to cut them out.
  ///
  /// A failed run is deleted rather than kept under a separate id: the file
  /// would upload alongside real runs, carry the same experiment id prefix,
  /// and every analysis would have to filter it out. This is the one place to
  /// change if an aborted recording ever needs keeping.
  ///
  /// Returns the path it deleted, or null if there was nothing to delete.
  Future<String?> discardAbortedExperiment(String id) async {
    final src = await _file(_expFileName(sanitizeExperimentId(id)));
    if (!await src.exists()) return null;
    final path = src.path;
    try {
      await src.delete();
      return path;
    } catch (e) {
      debugPrint('[exp] could not delete aborted $id: $e');
      return null;
    }
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
