import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String path;
  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _CapturingRecorder extends ExperimentRecorder {
  _CapturingRecorder({super.linkSnapshot});
  final List<Map<String, dynamic>> captured = [];
  @override
  Future<void> log(Map<String, dynamic> record) async => captured.add(record);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ExperimentRecorder recorder;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('trace_exp_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    recorder = ExperimentRecorder();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  List<Map<String, dynamic>> readJsonl(String path) => File(path)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => jsonDecode(l) as Map<String, dynamic>)
      .toList();

  group('a run never writes into another run\'s file', () {
    test('a trailing counter steps on when the file exists', () {
      expect(ExperimentRecorder.nextExperimentId('line-1'), 'line-2');
      expect(ExperimentRecorder.nextExperimentId('session-churn-9'),
          'session-churn-10');
    });

    test('digits that are not a run counter are left alone', () {
      // The 11 in dial-8-n11 is the node count. Counting it up would claim a
      // twelve-phone run that never happened.
      expect(ExperimentRecorder.nextExperimentId('dial-8-n11'),
          'dial-8-n11-2');
      expect(ExperimentRecorder.nextExperimentId('soak'), 'soak-2');
    });

    test('re-running the same id records under the next free one', () async {
      await recorder.startExperiment('churn-1');
      await recorder.logMarker('first run');
      expect(recorder.experimentId, 'churn-1');
      await recorder.stopExperiment();

      await recorder.startExperiment('churn-1');
      expect(recorder.experimentId, 'churn-2',
          reason: 'churn-1 is on disk, so this run is churn-2');
      await recorder.logMarker('second run');
      await recorder.stopExperiment();

      await recorder.startExperiment('churn-1');
      expect(recorder.experimentId, 'churn-3');
      await recorder.stopExperiment();

      // The first run's file still holds only the first run.
      final paths = await recorder.experimentFilePaths();
      expect(paths, hasLength(3));
      final first = readJsonl(
          paths.singleWhere((p) => p.endsWith('/exp_churn-1.jsonl')));
      expect(first.where((r) => r['label'] == 'second run'), isEmpty,
          reason: 'the whole point: no run appends to an earlier run');
      expect(first.where((r) => r['label'] == 'first run'), hasLength(1));
      expect(paths.where((p) => p.endsWith('/exp_churn-2.jsonl')),
          hasLength(1));
    });
  });

  test('records land in the experiment file while recording', () async {
    expect(recorder.active, isFalse);
    await recorder.startExperiment('cp-line-1');
    expect(recorder.active, isTrue);
    await recorder.log({'type': 'rssi', 't': 1, 'rssi': -60});
    await recorder.stopExperiment();
    expect(recorder.active, isFalse);

    final paths = await recorder.experimentFilePaths();
    expect(paths, hasLength(1));
    expect(paths.single, endsWith('exp_cp-line-1.jsonl'));

    final records = readJsonl(paths.single);
    // expStart marker, the rssi record, expStop marker — in order.
    // `buf` occupancy snapshots ride the same stream (baseline at start,
    // final at stop) — assert on the non-buf sequence, and that buf records
    // exist at both boundaries.
    final nonBuf = records.where((r) => r['type'] != 'buf').toList();
    expect(nonBuf[0]['event'], 'expStart');
    expect(nonBuf[1]['type'], 'rssi');
    expect(nonBuf[2]['event'], 'expStop');
    expect(records.where((r) => r['type'] == 'buf'), isNotEmpty,
        reason: 'occupancy is sampled at the start boundary');
  });

  test('power probe: sampled at start, records tagged, stops with the run',
      () async {
    var reads = 0;
    final probed = ExperimentRecorder(powerProbe: () async {
      reads++;
      return {'currentNowUa': -350000, 'levelPct': 81, 'charging': false};
    });
    await probed.startExperiment('pw');
    // The start-boundary baseline sample fires immediately.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reads, 1);
    await probed.stopExperiment();

    final paths = await probed.experimentFilePaths();
    final records = readJsonl(paths.single);
    final power = records.where((r) => r['type'] == 'power').toList();
    // Two boundary samples: the start baseline and the final reading at
    // stop (which closes the run's sub-10s tail).
    expect(power, hasLength(2));
    expect(power.first['currentNowUa'], -350000);
    expect(power.first['charging'], isFalse);
    expect(power.first['t'], isA<int>());
    expect(power.last['final'], isTrue,
        reason: 'the stop-boundary sample is tagged');

    // Stopped: the periodic timer must not keep probing.
    final after = reads;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reads, after);
  });

  test('a failing or null power probe records nothing and does not crash',
      () async {
    final probed = ExperimentRecorder(powerProbe: () async => null);
    await probed.startExperiment('pw2');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await probed.stopExperiment();
    final paths = await probed.experimentFilePaths();
    final records = readJsonl(
        paths.singleWhere((p) => p.endsWith('exp_pw2.jsonl')));
    expect(records.where((r) => r['type'] == 'power'), isEmpty);
  });

  test('an explicit flush lands on disk without losing the tail at stop',
      () async {
    // Nothing flushes on a timer — disk I/O inside a measurement window
    // costs power and CPU, and the buffer's size scales with traffic, so a
    // periodic write would bias the busiest condition. Uploads/shares DO
    // flush mid-run, and that path must not lose the tail.
    await recorder.startExperiment('flush');
    await recorder.log({'type': 'rssi', 't': 1, 'rssi': -50});
    await recorder.flushForTest();

    final path = (await recorder.experimentFilePaths()).single;
    final midRun = readJsonl(path);
    expect(midRun.where((r) => r['type'] == 'rssi'), hasLength(1),
        reason: 'flushed records are on disk before the run ends');

    await recorder.log({'type': 'rssi', 't': 2, 'rssi': -60});
    await recorder.stopExperiment();

    final all = readJsonl(path);
    expect(all.where((r) => r['type'] == 'rssi'), hasLength(2),
        reason: 'the post-flush tail is not lost');
    expect(
        all
            .where((r) => r['type'] != 'buf')
            .map((r) => r['event'] ?? r['t'])
            .toList(),
        ['expStart', 1, 2, 'expStop'],
        reason: 'appends stay in order across the flush boundary');
  });

  test('concurrent flushes (upload racing stop) do not interleave or drop',
      () async {
    await recorder.startExperiment('race');
    for (var i = 0; i < 200; i++) {
      await recorder.log({'type': 'rssi', 't': i, 'rssi': -i});
    }
    // Two flushes racing with the stop — the write chain must serialize them.
    final a = recorder.flushForTest();
    final b = recorder.flushForTest();
    await Future.wait([a, b]);
    await recorder.stopExperiment();

    final records = readJsonl((await recorder.experimentFilePaths()).single);
    final rssi = records.where((r) => r['type'] == 'rssi').toList();
    expect(rssi, hasLength(200));
    expect(rssi.map((r) => r['t']), List.generate(200, (i) => i),
        reason: 'no record lost, no order scrambled');
  });

  test('log is a no-op when no experiment is active', () async {
    await recorder.log({'type': 'rssi', 't': 2});
    expect(await recorder.experimentFilePaths(), isEmpty);

    await recorder.startExperiment('e');
    await recorder.stopExperiment();
    await recorder.log({'type': 'rssi', 't': 3});
    final records = readJsonl((await recorder.experimentFilePaths()).single);
    expect(records.map((r) => r['type']),
        everyElement(anyOf(equals('marker'), equals('buf'))),
        reason: 'only run-boundary records (markers + occupancy snapshots) — '
            'nothing logged outside an active experiment');
  });

  test('restarting the same id opens a new file, never resumes the old one',
      () async {
    await recorder.startExperiment('resume');
    await recorder.log({'type': 'rssi', 't': 1});
    await recorder.stopExperiment();
    await recorder.startExperiment('resume');
    await recorder.stopExperiment();

    final paths = await recorder.experimentFilePaths();
    expect(paths, hasLength(2), reason: 'one file per run');
    List<Object?> eventsOf(String name) => readJsonl(
            paths.singleWhere((p) => p.endsWith('/exp_$name.jsonl')))
        .where((r) => r['type'] != 'buf')
        .map((r) => r['event'] ?? r['type'])
        .toList();
    expect(eventsOf('resume'), ['expStart', 'rssi', 'expStop'],
        reason: 'the first run keeps exactly its own records');
    expect(eventsOf('resume-2'), ['expStart', 'expStop']);
  });

  test('experiment ids are sanitized to safe filenames', () async {
    expect(ExperimentRecorder.sanitizeExperimentId(' cp line/1 '), 'cp_line_1');
    expect(ExperimentRecorder.sanitizeExperimentId('///'), '___');
    expect(ExperimentRecorder.sanitizeExperimentId(''), 'exp');
  });

  test('logMarker stamps a note record with the experiment id', () async {
    await recorder.startExperiment('m1');
    await recorder.logMarker('d=80m approaching');
    final records = readJsonl((await recorder.experimentFilePaths()).single);
    final note = records.singleWhere((r) => r['event'] == 'note');
    expect(note['label'], 'd=80m approaching');
    expect(note['exp'], 'm1');
    await recorder.stopExperiment();
  });

  test('no records are dropped under a burst of concurrent unawaited logs',
      () async {
    // Regression: the old per-call writeAsString(append) fired concurrent
    // opens and silently dropped records under load (a 40-min soak lost ~a
    // third of its recv records). The persistent sink must keep every one.
    await recorder.startExperiment('burst');
    const n = 1000;
    // Fire without awaiting, exactly as the instrumentation does.
    for (var i = 0; i < n; i++) {
      unawaited(recorder.log({'type': 'x', 'i': i}));
    }
    await recorder.stopExperiment(); // flushes + closes

    final records = readJsonl((await recorder.experimentFilePaths()).single);
    final xs = records.where((r) => r['type'] == 'x').map((r) => r['i']).toSet();
    expect(xs, hasLength(n), reason: 'every concurrent log must be persisted');
    for (var i = 0; i < n; i++) {
      expect(xs, contains(i));
    }
  });

  test('clearExperimentFiles deletes everything; size reflects the live file',
      () async {
    await recorder.startExperiment('a');
    await recorder.log({'type': 'x'});
    expect(await recorder.experimentFileSize(), greaterThan(0));
    await recorder.stopExperiment();

    await recorder.startExperiment('b');
    await recorder.stopExperiment();
    expect(await recorder.experimentFilePaths(), hasLength(2));

    await recorder.clearExperimentFiles();
    expect(await recorder.experimentFilePaths(), isEmpty);
  });

  group('discharge runs', () {
    test('flushes on state-of-charge drop, so a dying phone keeps its trace',
        () async {
      var level = 100;
      final rec = ExperimentRecorder(
        flushEverySocDrop: 5,
        powerProbe: () async =>
            {'currentNowUa': -300000, 'levelPct': level, 'charging': false},
      );
      await rec.startExperiment('dis');
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // Nothing on disk yet beyond the baseline sample's own flush point.
      await rec.log({'type': 'rssi', 't': 1});
      level = 94; // a 6-point drop crosses the threshold
      await rec.forcePowerSampleForTest();

      final path = (await rec.experimentFilePaths()).single;
      final onDisk = readJsonl(path);
      expect(onDisk.where((r) => r['type'] == 'rssi'), hasLength(1),
          reason: 'the SoC drop flushed the buffer mid-run');
      await rec.stopExperiment();
    });

    test('the default floor is 5% — a mesh run wants the phone present', () {
      // A discharge run stops at 15% because battery saver changes the
      // system. A mesh run would rather have a degraded phone limping to the
      // end than a hole in the topology for every remaining step.
      expect(ExperimentRecorder().batteryFloorPct, 5);
    });

    test('live links are snapshotted right after expStart', () async {
      // An event-replaying topology reconstruction cannot see an edge whose
      // connect predates the recording — the home preflight drew its
      // founding trio at degree 0 while delivering 99.9% of sends.
      final rec = _CapturingRecorder(
        linkSnapshot: () => [
          {'type': 'link', 'event': 'connected', 'path': 'central:AA',
           'snapshot': true, 'peer': 'ff'},
        ],
      );
      await rec.startExperiment('snap');
      expect(rec.captured.map((r) => r['type']),
          containsAllInOrder(['marker', 'link']));
      final snap = rec.captured.lastWhere((r) => r['type'] == 'link');
      expect(snap['snapshot'], isTrue);
      expect(snap['path'], 'central:AA');
      await rec.stopExperiment();
    });

    test('reports the battery floor once, and only while discharging',
        () async {
      var level = 20;
      var charging = true;
      final fired = <int>[];
      final rec = ExperimentRecorder(
        batteryFloorPct: 15,
        powerProbe: () async => {
          'currentNowUa': -300000,
          'levelPct': level,
          'charging': charging,
        },
      );
      rec.onBatteryFloor = fired.add;
      await rec.startExperiment('floor');

      level = 12; // at the floor, but on a cable — not discharging
      await rec.forcePowerSampleForTest();
      expect(fired, isEmpty, reason: 'a charging phone is not approaching it');

      charging = false;
      await rec.forcePowerSampleForTest();
      expect(fired, [12]);

      level = 11;
      await rec.forcePowerSampleForTest();
      expect(fired, [12], reason: 'one-shot: the run ends on the first crossing');
      await rec.stopExperiment();
    });
  });

  _uploadTests();
}

/// Captures every upload POST, and can be told to fail a specific chunk so
/// the resume path is exercised.
class _CapturingClient extends http.BaseClient {
  final List<Map<String, dynamic>> envelopes = [];
  final List<int> bodyBytes = [];
  int? failAtCall;
  int _calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    bodyBytes.add(body.length);
    envelopes.add(
        jsonDecode(utf8.decode(gzip.decode(body))) as Map<String, dynamic>);
    final n = _calls++;
    final code = (failAtCall != null && n == failAtCall) ? 500 : 200;
    return http.StreamedResponse(const Stream.empty(), code);
  }
}

void _uploadTests() {
  late Directory tmp;
  late ExperimentRecorder recorder;
  late _CapturingClient client;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('exp-upload');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    client = _CapturingClient();
    recorder = ExperimentRecorder(httpClient: client);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<void> writeRecords(int n) async {
    await recorder.startExperiment('chunky');
    for (var i = 0; i < n; i++) {
      await recorder.log({'type': 'rssi', 't': i, 'rssi': -i});
    }
    await recorder.stopExperiment();
  }

  test('splits a large file into bounded chunks covering every record',
      () async {
    // 2.5x the chunk size, so the split is exercised in both directions.
    final n = ExperimentRecorder.uploadChunkRecords * 2 + 500;
    await writeRecords(n);

    final msg = await recorder.uploadExperimentFiles(
        url: 'http://x', token: 't', deviceId: 'devA');

    expect(msg.complete, isTrue, reason: 'every chunk landed');
    expect(client.envelopes.length, greaterThan(1), reason: 'it chunked');
    for (final e in client.envelopes) {
      expect((e['records'] as List).length,
          lessThanOrEqualTo(ExperimentRecorder.uploadChunkRecords),
          reason: 'no chunk exceeds the bound — that bound IS the peak memory');
    }
    // Every rssi record arrives exactly once, in order, across the chunks.
    final ts = [
      for (final e in client.envelopes)
        for (final r in (e['records'] as List))
          if (r['type'] == 'rssi') r['t'] as int
    ];
    expect(ts, List.generate(n, (i) => i));
    expect(msg.message, contains('chunk'));
  });

  test('progress is reported per chunk and reaches 100%', () async {
    // Bytes read, not chunks: the chunk total is not knowable in advance
    // because the file is streamed, so a chunk-count bar would have no
    // denominator until the upload was already over.
    await writeRecords(ExperimentRecorder.uploadChunkRecords * 2 + 100);
    final seen = <(int, double)>[];
    recorder.onUploadProgress = (file, chunks, frac) => seen.add((chunks, frac));

    await recorder.uploadExperimentFiles(
        url: 'http://x', token: 't', deviceId: 'devA');

    expect(seen.length, greaterThan(1), reason: 'one report per chunk');
    expect(seen.map((e) => e.$1).toList(), [for (var i = 1; i <= seen.length; i++) i],
        reason: 'chunk numbers count up without gaps');
    // Monotonic, and finishing at the whole file.
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].$2, greaterThanOrEqualTo(seen[i - 1].$2));
    }
    expect(seen.last.$2, closeTo(1.0, 0.02));
  });

  test('chunk ids are distinct and stable, so a retry resumes', () async {
    await writeRecords(ExperimentRecorder.uploadChunkRecords + 10);

    await recorder.uploadExperimentFiles(
        url: 'http://x', token: 't', deviceId: 'devA');
    final first = client.envelopes.map((e) => e['uploadId']).toList();
    expect(first.toSet().length, first.length, reason: 'ids are distinct');

    client.envelopes.clear();
    await recorder.uploadExperimentFiles(
        url: 'http://x', token: 't', deviceId: 'devA');
    final second = client.envelopes.map((e) => e['uploadId']).toList();

    // Same ids on the retry: the server dedupes on uploadId, so re-sending
    // costs nothing and only the missing chunks actually land.
    expect(second, first);
  });

  test('a failed chunk stops the file and reports it as resumable', () async {
    await writeRecords(ExperimentRecorder.uploadChunkRecords * 2 + 5);
    client.failAtCall = 1; // second chunk rejected

    final msg = await recorder.uploadExperimentFiles(
        url: 'http://x', token: 't', deviceId: 'devA');

    expect(msg.message, contains('failed'));
    expect(msg.message, contains('resume'));
    expect(msg.complete, isFalse,
        reason: 'a partial sweep must never report complete — that is what '
            'let a re-press store the file prefix twice');
    expect(client.envelopes.length, 2,
        reason: 'it stopped at the failure rather than burning the rest');
  });
}
