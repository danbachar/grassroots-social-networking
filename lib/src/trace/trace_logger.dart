import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Opt-in trace logging (see `trace_server/schema.md`).
///
/// Records are opaque `{type, t, ...}` maps appended to a durable JSONL buffer
/// under the app documents dir. On the daily prompt the buffer is promoted to an
/// immutable "pending" batch, uploaded to the user's trace server (gzip, bearer
/// auth), and deleted on success. Privacy decisions (locked):
/// - device id is a **fresh UUID per upload** (unlinkable across uploads),
/// - peer pubkeys are replaced with **per-upload aliases** (`p0`, `p1`, …),
/// - logging only happens when [enabled] (gated on the user's consent).
///
/// Uploads are idempotent: the `uploadId` is generated once per pending batch
/// and reused across retries (stored in a sidecar), so a lost response never
/// double-stores. New records accumulate in a fresh buffer while a pending batch
/// is in flight or stuck, so a failing upload never blocks logging.
class TraceLogger {
  static const _uuid = Uuid();
  static const _subdir = 'trace';
  static const _bufferName = 'trace_buffer.jsonl';
  static const _pendingName = 'trace_pending.jsonl';
  static const _pendingMetaName = 'trace_pending.meta.json';

  /// Cap the live buffer; when exceeded, the oldest half is dropped.
  static const int maxBufferBytes = 8 * 1024 * 1024;
  static const int schemaVersion = 1;
  static const Duration uploadTimeout = Duration(seconds: 30);

  /// 'android' | 'ios' | … — uploaded verbatim as envelope metadata.
  final String platform;

  bool _enabled = false;
  bool get enabled => _enabled;

  TraceLogger({required this.platform});

  /// Gate logging on consent. Records logged while disabled are dropped.
  void setEnabled(bool enabled) => _enabled = enabled;

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_subdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String name) async => File('${(await _dir()).path}/$name');

  /// Append one trace record. No-op when disabled; never throws.
  Future<void> log(Map<String, dynamic> record) async {
    if (!_enabled) return;
    try {
      final buffer = await _file(_bufferName);
      await buffer.writeAsString('${jsonEncode(record)}\n',
          mode: FileMode.append, flush: false);
      if (await buffer.length() > maxBufferBytes) {
        await _trimOldest(buffer);
      }
    } catch (e) {
      debugPrint('[trace] log failed: $e');
    }
  }

  /// True if there is anything to upload (a stuck pending batch or live buffer).
  Future<bool> hasUnuploaded() async {
    final pending = await _file(_pendingName);
    if (await pending.exists() && await pending.length() > 0) return true;
    final buffer = await _file(_bufferName);
    return await buffer.exists() && await buffer.length() > 0;
  }

  /// Upload all not-yet-uploaded records to [url] with bearer [token].
  /// Returns true on success (or when there is nothing to upload).
  Future<bool> uploadAll({required String url, required String token}) async {
    try {
      final pending = await _file(_pendingName);
      final meta = await _file(_pendingMetaName);

      // Promote the live buffer to an immutable pending batch — but only if no
      // pending batch is already in flight, so each batch keeps a stable
      // uploadId and new logs keep flowing into a fresh buffer.
      if (!await pending.exists()) {
        final buffer = await _file(_bufferName);
        if (!await buffer.exists() || await buffer.length() == 0) {
          return true; // nothing to upload
        }
        await buffer.rename(pending.path);
        await meta.writeAsString(jsonEncode({
          'uploadId': _uuid.v4(),
          'deviceId': _uuid.v4(), // rotating per-upload
        }));
      }

      final records = await _readRecords(pending);
      if (records.isEmpty) {
        await _safeDelete(pending);
        await _safeDelete(meta);
        return true;
      }

      final metaJson = await meta.exists()
          ? jsonDecode(await meta.readAsString()) as Map<String, dynamic>
          : {'uploadId': _uuid.v4(), 'deviceId': _uuid.v4()};

      final envelope = _buildEnvelope(
        records,
        uploadId: metaJson['uploadId'] as String,
        deviceId: metaJson['deviceId'] as String,
      );
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
          .timeout(uploadTimeout);

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        await _safeDelete(pending);
        await _safeDelete(meta);
        debugPrint('[trace] uploaded ${records.length} records '
            '(${resp.statusCode})');
        return true;
      }
      debugPrint('[trace] upload rejected: HTTP ${resp.statusCode}');
      return false; // keep pending for retry
    } catch (e) {
      debugPrint('[trace] upload error: $e');
      return false; // keep pending for retry
    }
  }

  /// Discard all buffered + pending records (e.g. on consent withdrawal).
  Future<void> clear() async {
    await _safeDelete(await _file(_bufferName));
    await _safeDelete(await _file(_pendingName));
    await _safeDelete(await _file(_pendingMetaName));
  }

  Map<String, dynamic> _buildEnvelope(
    List<Map<String, dynamic>> records, {
    required String uploadId,
    required String deviceId,
  }) {
    // Replace peer pubkeys with per-upload aliases so a node pair stays
    // correlatable within the batch but not across uploads/devices.
    final aliases = <String, String>{};
    String aliasFor(String pubkey) =>
        aliases.putIfAbsent(pubkey, () => 'p${aliases.length}');

    final rewritten = records.map((r) {
      final peer = r['peer'];
      if (peer is String && peer.isNotEmpty) {
        return {...r, 'peer': aliasFor(peer)};
      }
      return r;
    }).toList(growable: false);

    return {
      'schemaVersion': schemaVersion,
      'uploadId': uploadId,
      'deviceId': deviceId,
      'platform': platform,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'consent': true,
      'records': rewritten,
    };
  }

  Future<List<Map<String, dynamic>>> _readRecords(File f) async {
    if (!await f.exists()) return const [];
    final out = <Map<String, dynamic>>[];
    for (final line in (await f.readAsString()).split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {
        // skip a corrupt line rather than failing the whole upload
      }
    }
    return out;
  }

  Future<void> _trimOldest(File buffer) async {
    try {
      final lines =
          (await buffer.readAsString()).split('\n').where((l) => l.isNotEmpty);
      final kept = lines.toList();
      final half = kept.sublist(kept.length ~/ 2);
      await buffer.writeAsString('${half.join('\n')}\n');
      debugPrint('[trace] buffer trimmed to ${half.length} records');
    } catch (e) {
      debugPrint('[trace] trim failed: $e');
    }
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String _normalizeBase(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }
}
