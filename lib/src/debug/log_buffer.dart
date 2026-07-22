import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:logger/logger.dart' show Level;
import 'package:path_provider/path_provider.dart';

/// A log entry captured from the logger.
class LogEntry {
  final Level level;
  final String message;
  final DateTime timestamp;

  LogEntry({
    required this.level,
    required this.message,
    required this.timestamp,
  });

  String get levelLabel {
    switch (level) {
      case Level.trace:
        return 'TRACE';
      case Level.debug:
        return 'DEBUG';
      case Level.info:
        return 'INFO';
      case Level.warning:
        return 'WARN';
      case Level.error:
        return 'ERROR';
      case Level.fatal:
        return 'FATAL';
      default:
        return level.name.toUpperCase();
    }
  }

  /// Human-readable persisted form: `[iso8601] LEVEL message`. Newlines in the
  /// message are escaped so one entry stays one line.
  String toFileLine() =>
      '[${timestamp.toIso8601String()}] $levelLabel '
      '${message.replaceAll('\n', '\\n')}';

  static final _fileLineRe = RegExp(r'^\[([^\]]+)\] (\w+) (.*)$');

  /// Best-effort reverse of [toFileLine]. A line that doesn't match is kept
  /// verbatim at debug level rather than dropped.
  factory LogEntry.fromFileLine(String line) {
    final m = _fileLineRe.firstMatch(line);
    if (m == null) {
      return LogEntry(
          level: Level.debug, message: line, timestamp: DateTime.now());
    }
    return LogEntry(
      level: _levelFromLabel(m.group(2)!),
      message: m.group(3)!.replaceAll('\\n', '\n'),
      timestamp: DateTime.tryParse(m.group(1)!) ?? DateTime.now(),
    );
  }

  static Level _levelFromLabel(String label) {
    switch (label) {
      case 'TRACE':
        return Level.trace;
      case 'INFO':
        return Level.info;
      case 'WARN':
        return Level.warning;
      case 'ERROR':
        return Level.error;
      case 'FATAL':
        return Level.fatal;
      default:
        return Level.debug;
    }
  }
}

/// Global log buffer that captures logger output and PERSISTS it to disk so it
/// survives app restarts and crashes.
///
/// Install as a [LogOutput] on all Logger instances. In memory it is a ring
/// buffer ([maxEntries]); on disk it is an append-only file flushed on a short
/// timer (so a crash loses at most [_flushInterval] of tail) and rotated at
/// [_maxFileBytes]. Call [init] once at startup to load prior logs and begin
/// persisting.
class LogBuffer {
  static final LogBuffer instance = LogBuffer._();

  /// Maximum number of log entries kept in memory.
  static const int maxEntries = 2000;

  /// Rotate the on-disk file when it grows past this (keep the newer half).
  static const int _maxFileBytes = 4 * 1024 * 1024;

  static const Duration _flushInterval = Duration(milliseconds: 700);

  final _entries = Queue<LogEntry>();
  final _listeners = <void Function()>[];
  final _pending = <String>[];
  File? _file;
  Timer? _flushTimer;
  bool _initialized = false;

  LogBuffer._();

  /// All captured log entries (oldest first).
  List<LogEntry> get entries => _entries.toList();

  /// Number of entries currently stored.
  int get length => _entries.length;

  /// Absolute path of the persisted log file (null until [init] runs).
  String? get logFilePath => _file?.path;

  /// Register a listener that's called when new entries arrive.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Remove a previously registered listener.
  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Load persisted logs into memory and start persisting new ones. Idempotent;
  /// best-effort (logging must never crash the app).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/grassroots_debug.log');
      if (await f.exists()) {
        if (await f.length() > _maxFileBytes) {
          final content = await f.readAsString();
          await f.writeAsString(
              content.substring(content.length - _maxFileBytes ~/ 2));
        }
        final lines = await f.readAsLines();
        final start = lines.length > maxEntries ? lines.length - maxEntries : 0;
        for (final line in lines.sublist(start)) {
          if (line.trim().isEmpty) continue;
          _entries.addLast(LogEntry.fromFileLine(line));
        }
        while (_entries.length > maxEntries) {
          _entries.removeFirst();
        }
      }
      _file = f;
      _flushTimer = Timer.periodic(_flushInterval, (_) => _flush());
    } catch (_) {
      // Best effort — keep buffering in memory even if disk is unavailable.
    }
    addEntry(LogEntry(
      level: Level.info,
      timestamp: DateTime.now(),
      message: '════════ app started ════════',
    ));
    _notifyListeners();
  }

  /// Add a single log entry.
  void addEntry(LogEntry entry) {
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    _pending.add(entry.toFileLine());
    _notifyListeners();
  }

  Future<void> _flush() async {
    final file = _file;
    if (_pending.isEmpty || file == null) return;
    final batch = '${_pending.join('\n')}\n';
    _pending.clear();
    try {
      await file.writeAsString(batch, mode: FileMode.append, flush: true);
    } catch (_) {
      // Drop this batch rather than let it accumulate unbounded.
    }
  }

  /// Force any pending lines to disk (call on app pause / detach so the tail
  /// before a background kill is not lost).
  Future<void> flushNow() => _flush();

  /// Stop the periodic flusher (final flush first). The app never tears the
  /// singleton down, but tests do.
  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }

  /// Clear all entries, in memory and on disk.
  Future<void> clear() async {
    _entries.clear();
    _pending.clear();
    try {
      await _file?.writeAsString('');
    } catch (_) {}
    _notifyListeners();
  }

  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }
}
