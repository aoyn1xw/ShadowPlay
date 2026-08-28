import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../shared/widgets.dart';

class ClipsScreen extends StatefulWidget {
  const ClipsScreen({required this.state, super.key});
  final AppState state;

  @override
  State<ClipsScreen> createState() => _ClipsScreenState();
}

class _ClipsScreenState extends State<ClipsScreen> {
  final Set<String> _selectedIds = {};

  Future<void> _downloadSelected() async {
    final selected = widget.state.newClips
        .where((clip) => _selectedIds.contains(clip.id))
        .toList();
    await widget.state.downloadClips(selected);
    if (!mounted) return;
    setState(
        () => _selectedIds.removeWhere(widget.state.downloadedIds.contains));
    final failures = selected
        .where((clip) => widget.state.downloadFailures.containsKey(clip.id))
        .length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(failures == 0
            ? 'Download complete. Your clips are now in Home.'
            : '$failures ${failures == 1 ? 'download' : 'downloads'} failed. Tap the clip to retry.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.state.active;
    final clips = widget.state.newClips;
    if (active == null) {
      return const EmptyState(
        icon: Icons.desktop_access_disabled,
        title: 'No PC paired',
        message: 'Open Settings to pair a PC.',
      );
    }
    _selectedIds.removeWhere((id) => !clips.any((clip) => clip.id == id));
    return Column(
      children: [
        DeviceHeader(
          connection: active,
          status: widget.state.activeStatus,
          lastSyncUtc: widget.state.lastSyncUtc,
        ),
        Expanded(child: _content(clips)),
        if (_selectedIds.isNotEmpty)
          SelectionActionBar(
            count: _selectedIds.length,
            busy: widget.state.isDownloading,
            onDownload: _downloadSelected,
          ),
      ],
    );
  }

  Widget _content(List<Clip> clips) {
    if (widget.state.clipsLoading && widget.state.remoteClips.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.state.activeStatus.availability == DeviceAvailability.offline &&
        widget.state.remoteClips.isEmpty) {
      return EmptyState(
        icon: Icons.wifi_off,
        title: 'PC is offline',
        message: widget.state.clipLoadError ??
            'Make sure the PC is running and on the same Wi-Fi network.',
        action: FilledButton.tonal(
          onPressed: widget.state.refreshClips,
          child: const Text('Try Again'),
        ),
      );
    }
    if (clips.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        title: 'No new clips',
        message: 'You are all caught up. Pull down to check again.',
        action: OutlinedButton.icon(
          onPressed: widget.state.refreshClips,
          icon: const Icon(Icons.refresh),
          label: const Text('Refresh'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: widget.state.refreshClips,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: clips.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.82,
        ),
        itemBuilder: (context, index) {
          final clip = clips[index];
          final selected = _selectedIds.contains(clip.id);
          return _RemoteClipCard(
            clip: clip,
            selected: selected,
            progress: widget.state.downloadProgress[clip.id],
            downloading: widget.state.downloadProgress.containsKey(clip.id),
            failed: widget.state.downloadFailures[clip.id],
            onTap: () => setState(() {
              if (!selected) {
                _selectedIds.add(clip.id);
              } else {
                _selectedIds.remove(clip.id);
              }
            }),
          );
        },
      ),
    );
  }
}

class _RemoteClipCard extends StatelessWidget {
  const _RemoteClipCard({
    required this.clip,
    required this.selected,
    required this.downloading,
    required this.onTap,
    this.progress,
    this.failed,
  });

  final Clip clip;
  final bool selected;
  final bool downloading;
  final double? progress;
  final String? failed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      clipBehavior: ui.Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: downloading ? null : onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipPoster(
                      badge: formatBytes(clip.sizeBytes), selected: selected),
                  if (downloading)
                    ColoredBox(
                      color: Colors.black45,
                      child: Center(
                        child: SizedBox(
                          width: 46,
                          height: 46,
                          child: CircularProgressIndicator(
                            value: progress,
                            color: Colors.white,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                clip.fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                failed == null
                    ? formatClipDate(clip.lastWriteTimeUtc)
                    : 'Download failed · tap to retry',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: failed == null
                          ? colors.onSurfaceVariant
                          : colors.error,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SelectionActionBar extends StatelessWidget {
  const SelectionActionBar({
    required this.count,
    required this.busy,
    required this.onDownload,
    super.key,
  });

  final int count;
  final bool busy;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 3,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$count selected',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                FilledButton.icon(
                  onPressed: busy ? null : onDownload,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download),
                  label: Text(busy
                      ? 'Downloading…'
                      : 'Download $count ${count == 1 ? 'clip' : 'clips'}'),
                ),
              ],
            ),
          ),
        ),
      );
}
