import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_state.dart';
import '../../core/diagnostics.dart';
import '../../shared/widgets.dart';

typedef ReportSharer = Future<void> Function(String path);

/// Hands a generated report to the platform share sheet. Lives in the
/// feature layer so tests can replace it.
Future<void> shareDiagnosticsReport(String path) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(path)],
      text: 'ShadowPlay diagnostics report',
    ),
  );
}

/// In-app diagnostics viewer: recent events, storage state, and the export
/// and clear actions. All data is local; nothing leaves the device except
/// through the share sheet the user invokes.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({
    required this.state,
    this.onShare = shareDiagnosticsReport,
    super.key,
  });

  final AppState state;
  final ReportSharer onShare;

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  List<DiagnosticEntry> _entries = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    setState(() {
      _entries = widget.state.diagnostics.recent(limit: 400);
    });
  }

  Future<void> _exportReport() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final path = await widget.state.diagnostics.exportReport();
      await widget.onShare(path);
    } catch (error) {
      messenger.showSnackBar(SnackBar(
        content: Text('Could not open the share sheet: $error'),
      ));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _clearLogs() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear diagnostic logs?'),
        content: const Text(
            'All locally stored diagnostic events are erased. The verbose '
            'setting is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear Logs'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.state.diagnostics.clear();
      _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
          const SnackBar(content: Text('Diagnostic logs cleared')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final diagnostics = widget.state.diagnostics;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Export report',
            onPressed: _busy ? null : _exportReport,
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: 'Clear logs',
            onPressed: _busy ? null : _clearLogs,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _reload();
          await diagnostics.flush();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Material(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Local diagnostics',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Icon(
                          diagnostics.verbose
                              ? Icons.bug_report
                              : Icons.bug_report_outlined,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      diagnostics.attached
                          ? 'Storage: '
                              '${_formatBytes(diagnostics.storageBytes)} of '
                              '${_formatBytes(diagnostics.maxTotalBytes)} · rotation on'
                          : 'Storage: unavailable, events are kept in memory '
                              'for this session only',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (diagnostics.writeFailures > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Write failures: ${diagnostics.writeFailures}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.error),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'Bearer tokens, pairing codes, private keys, '
                      'certificate contents, and private file paths are '
                      'redacted before anything is stored. Logs leave this '
                      'device only when you share the exported report.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 40, 20, 0),
                child: EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No events yet',
                  message: 'Events appear here as the app runs.',
                ),
              )
            else
              for (final entry in _entries)
                _EntryTile(
                  entry: entry,
                  onTap: () => _showDetails(entry),
                ),
          ],
        ),
      ),
    );
  }

  void _showDetails(DiagnosticEntry entry) {
    final time = entry.timeUtc.toLocal();
    final lines = <String>[
      'time (local): $time',
      'time (UTC):   ${entry.timeUtc.toIso8601String()}Z',
      'severity:     ${entry.severity.label}',
      'component:    ${entry.component}',
      ...entry.context.entries.map((e) => '${e.key}: ${e.value}'),
      '',
      entry.message,
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Event details'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: SelectableText(lines.join('\n')),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    final kilobytes = bytes / 1024;
    if (kilobytes < 1024) return '${kilobytes.toStringAsFixed(1)}KB';
    return '${(kilobytes / 1024).toStringAsFixed(1)}MB';
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});

  final DiagnosticEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (entry.severity) {
      DiagnosticSeverity.debug => (Icons.bug_report_outlined, scheme.primary),
      DiagnosticSeverity.info => (Icons.info_outline, scheme.onSurfaceVariant),
      DiagnosticSeverity.warning => (
          Icons.warning_amber_rounded,
          const Color(0xFFB8860B)
        ),
      DiagnosticSeverity.error => (Icons.error_outline, scheme.error),
    };
    final subtitleParts = <String>[
      _clock(entry.timeUtc),
      entry.component,
      if (entry.context.isNotEmpty) entry.context.keys.join(', '),
    ];
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        entry.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitleParts.join(' · '), maxLines: 1),
      onTap: onTap,
    );
  }

  static String _clock(DateTime timeUtc) {
    final local = timeUtc.toLocal();
    String part(int value) => value.toString().padLeft(2, '0');
    return '${part(local.hour)}:${part(local.minute)}:${part(local.second)}';
  }
}
