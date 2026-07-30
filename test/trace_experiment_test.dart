import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/trace/experiment_recorder.dart';
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
    expect(records[0]['event'], 'expStart');
    expect(records[1]['type'], 'rssi');
    expect(records[2]['event'], 'expStop');
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
    expect(power, hasLength(1));
    expect(power.single['currentNowUa'], -350000);
    expect(power.single['charging'], isFalse);
    expect(power.single['t'], isA<int>());

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

  test('log is a no-op when no experiment is active', () async {
    await recorder.log({'type': 'rssi', 't': 2});
    expect(await recorder.experimentFilePaths(), isEmpty);

    await recorder.startExperiment('e');
    await recorder.stopExperiment();
    await recorder.log({'type': 'rssi', 't': 3});
    final records = readJsonl((await recorder.experimentFilePaths()).single);
    expect(records.map((r) => r['type']), everyElement(equals('marker')));
  });

  test('restarting the same id appends (resume) instead of truncating',
      () async {
    await recorder.startExperiment('resume');
    await recorder.log({'type': 'rssi', 't': 1});
    await recorder.stopExperiment();
    await recorder.startExperiment('resume');
    await recorder.stopExperiment();

    final paths = await recorder.experimentFilePaths();
    expect(paths, hasLength(1));
    final events = readJsonl(paths.single)
        .map((r) => r['event'] ?? r['type'])
        .toList();
    expect(events, ['expStart', 'rssi', 'expStop', 'expStart', 'expStop']);
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
}
