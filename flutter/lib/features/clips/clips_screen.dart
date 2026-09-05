import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../shared/widgets.dart';
import '../../shared/recording_row.dart';
import '../player/player_screen.dart';

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
    final galleryFailures = selected
        .where((clip) => widget.state.gallerySaveFailures.containsKey(clip.id))
        .length;
    final message = failures > 0
        ? '$failures ${failures == 1 ? 'download' : 'downloads'} failed. Tap the clip to retry.'
        : galleryFailures > 0
            ? 'Downloaded, but $galleryFailures clip${galleryFailures == 1 ? '' : 's'} could not be saved to Photos/Gallery. You can retry from Home.'
            : 'Download complete. Clips were saved to Home and Photos/Gallery.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
            child: RefreshIndicator(
          onRefresh: widget.state.refreshClips,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                  child: DeviceHeader(
                title: 'Clips on PC',
                connection: active,
                status: widget.state.activeStatus,
                lastSyncUtc: widget.state.lastSyncUtc,
              )),
              SliverToBoxAdapter(
                  child: LibraryHeading(
                title: 'New recordings',
                detail: '${clips.length} available · Select clips to download',
              )),
              _content(clips),
            ],
          ),
        )),
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
      return const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()));
    }
    if (widget.state.activeStatus.availability == DeviceAvailability.offline &&
        widget.state.remoteClips.isEmpty) {
      return SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.wifi_off,
            title: 'PC is offline',
            message: widget.state.clipLoadError ??
                'Make sure the PC is running and on the same Wi-Fi network.',
            action: FilledButton.tonal(
              onPressed: widget.state.refreshClips,
              child: const Text('Try Again'),
            ),
          ));
    }
    if (clips.isEmpty) {
      return SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.check_circle_outline,
            title: 'No new clips',
            message: 'You are all caught up. Pull down to check again.',
            action: OutlinedButton.icon(
              onPressed: widget.state.refreshClips,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ));
    }
    return SliverList.builder(
      itemCount: clips.length,
      itemBuilder: (context, index) {
        final clip = clips[index];
        final selected = _selectedIds.contains(clip.id);
        return _RemoteClipCard(
          clip: clip,
          loadThumbnail: widget.state.loadThumbnail,
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
          onPlay: () {
            final api = widget.state.api;
            if (api == null) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen.remote(clip: clip, api: api),
              ),
            );
          },
        );
      },
    );
  }
}

class _RemoteClipCard extends StatelessWidget {
  const _RemoteClipCard({
    required this.clip,
    required this.loadThumbnail,
    required this.selected,
    required this.downloading,
    required this.onTap,
    required this.onPlay,
    this.progress,
    this.failed,
  });

  final Clip clip;
  final Future<Uint8List?> Function(Clip clip) loadThumbnail;
  final bool selected;
  final bool downloading;
  final double? progress;
  final String? failed;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return RecordingRow(
      preview: Stack(fit: StackFit.expand, children: [
        _RemoteThumbnail(
            clip: clip, loadThumbnail: loadThumbnail, selected: false),
        Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Play from PC',
              style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white),
              onPressed: downloading ? null : onPlay,
              icon: const Icon(Icons.play_arrow),
            )),
      ]),
      fileName: clip.fileName,
      metadata:
          '${formatBytes(clip.sizeBytes)}\n${formatClipDate(clip.lastWriteTimeUtc)}',
      selected: selected,
      downloading: downloading,
      progress: progress,
      status: failed == null
          ? null
          : 'Download failed. Select and download to retry.',
      onTap: downloading ? null : onTap,
      action: IconButton(
        tooltip:
            selected ? 'Deselect ${clip.fileName}' : 'Select ${clip.fileName}',
        onPressed: downloading ? null : onTap,
        icon:
            Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked),
        color: selected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
    );
  }
}

class _RemoteThumbnail extends StatefulWidget {
  const _RemoteThumbnail({
    required this.clip,
    required this.loadThumbnail,
    required this.selected,
  });

  final Clip clip;
  final Future<Uint8List?> Function(Clip clip) loadThumbnail;
  final bool selected;

  @override
  State<_RemoteThumbnail> createState() => _RemoteThumbnailState();
}

class _RemoteThumbnailState extends State<_RemoteThumbnail> {
  late Future<Uint8List?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = widget.loadThumbnail(widget.clip);
  }

  @override
  void didUpdateWidget(covariant _RemoteThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clip.id != widget.clip.id ||
        oldWidget.clip.sizeBytes != widget.clip.sizeBytes ||
        oldWidget.clip.lastWriteTimeUtc != widget.clip.lastWriteTimeUtc) {
      _thumbnail = widget.loadThumbnail(widget.clip);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _thumbnail,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return ClipPoster(
              showIcon: false,
              badge: widget.clip.duration == null
                  ? formatBytes(widget.clip.sizeBytes)
                  : formatDuration(widget.clip.duration!),
              selected: widget.selected,
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
              if (widget.selected)
                ColoredBox(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.13)),
              Positioned(
                right: 8,
                bottom: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Text(
                      widget.clip.duration == null
                          ? formatBytes(widget.clip.sizeBytes)
                          : formatDuration(widget.clip.duration!),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              if (widget.selected)
                Positioned(
                  right: 8,
                  top: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.check, color: Colors.white, size: 16),
                    ),
                  ),
                ),
            ],
          );
        },
      );
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
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('$count selected',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
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
