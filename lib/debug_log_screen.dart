import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'src/debug/log_buffer.dart';
import 'theme/grasslink_tokens.dart';

/// Debug log viewer screen.
///
/// Shows all captured log entries with level filtering and auto-scroll.
class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  Level _minLevel = Level.info;
  bool _autoScroll = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    LogBuffer.instance.addListener(_onNewLog);
  }

  @override
  void dispose() {
    LogBuffer.instance.removeListener(_onNewLog);
    _scrollController.dispose();
    super.dispose();
  }

  void _onNewLog() {
    if (!mounted) return;
    setState(() {});
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  List<LogEntry> get _filteredEntries =>
      LogBuffer.instance.entries.where((e) => e.level.index >= _minLevel.index).toList();

  /// Flush pending lines, then save a copy of the persisted log to a NEW file
  /// named with the current save time — e.g. `grassroots-log-2026-07-20_13-45-30.txt`.
  /// Written to app-specific external storage on Android (adb-pullable, no
  /// permission), falling back to the documents dir.
  Future<void> _downloadLogs() async {
    await LogBuffer.instance.flushNow();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${now.year}-${two(now.month)}-${two(now.day)}_'
          '${two(now.hour)}-${two(now.minute)}-${two(now.second)}';

      final dir = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
      final dest = File('${dir.path}/grassroots-log-$stamp.txt');

      final srcPath = LogBuffer.instance.logFilePath;
      if (srcPath != null && await File(srcPath).exists()) {
        await File(srcPath).copy(dest.path);
      } else {
        // Persistence unavailable — dump the in-memory buffer instead.
        final text =
            LogBuffer.instance.entries.map((e) => e.toFileLine()).join('\n');
        await dest.writeAsString(text);
      }

      messenger.showSnackBar(SnackBar(
        content: Text('Saved to ${dest.path}'),
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save log: $e')));
    }
  }

  Color _colorForLevel(Level level) {
    switch (level) {
      case Level.trace:
        return GlColors.textSubtle;
      case Level.debug:
        return GlColors.textMuted;
      case Level.info:
        return GlColors.info;
      case Level.warning:
        return GlColors.warning;
      case Level.error:
        return GlColors.danger;
      case Level.fatal:
        return GlColors.rust400;
      default:
        return GlColors.textBody;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _filteredEntries;

    return Scaffold(
      appBar: AppBar(
        title: Text('Debug logs (${entries.length})'),
        actions: [
          // Auto-scroll toggle
          IconButton(
            icon: Icon(
              _autoScroll
                  ? Icons.vertical_align_bottom
                  : Icons.vertical_align_center,
              color: _autoScroll ? GlColors.success : GlColors.textSubtle,
            ),
            tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          // Copy all logs
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copy logs',
            onPressed: () {
              final text = entries
                  .map((e) => '[${e.levelLabel}] ${e.message}')
                  .join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Copied ${entries.length} log entries')),
              );
            },
          ),
          // Download / share the persisted log file
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Download logs',
            onPressed: _downloadLogs,
          ),
          // Clear logs
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
            onPressed: () async {
              await LogBuffer.instance.clear();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Level filter chips
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: GlSpace.s3, vertical: GlSpace.s2),
            color: GlColors.bgSunken,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildFilterChip('All', Level.trace),
                  const SizedBox(width: 6),
                  _buildFilterChip('Debug', Level.debug),
                  const SizedBox(width: 6),
                  _buildFilterChip('Info', Level.info),
                  const SizedBox(width: 6),
                  _buildFilterChip('Warn', Level.warning),
                  const SizedBox(width: 6),
                  _buildFilterChip('Error', Level.error),
                ],
              ),
            ),
          ),
          // Log list
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'No log entries',
                      style: TextStyle(color: GlColors.textMuted),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final time =
                          '${entry.timestamp.hour.toString().padLeft(2, '0')}:'
                          '${entry.timestamp.minute.toString().padLeft(2, '0')}:'
                          '${entry.timestamp.second.toString().padLeft(2, '0')}';

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 1),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 55,
                              child: Text(
                                time,
                                style: GlType.monoStyle(10,
                                    color: GlColors.textSubtle),
                              ),
                            ),
                            SizedBox(
                              width: 40,
                              child: Text(
                                entry.levelLabel,
                                style: GlType.monoStyle(10,
                                        color: _colorForLevel(entry.level))
                                    .copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                entry.message,
                                style: GlType.monoStyle(10,
                                    color: GlColors.textBody),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, Level level) {
    final isSelected = _minLevel == level;
    return GestureDetector(
      onTap: () => setState(() => _minLevel = level),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: GlSpace.s3, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? GlColors.primarySoft : GlColors.surfaceCard,
          borderRadius: GlRadius.rPill,
          border: Border.all(
            color: isSelected ? GlColors.primary : GlColors.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: GlType.textXs,
            color: isSelected ? GlColors.primaryOnSoft : GlColors.textMuted,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
