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
    final available = widget.state.remoteClips;
    final selected =
        available.where((clip) => _selectedIds.contains(clip.id)).toList();
    await widget.state.downloadClips(selected);
    if (!mounted) return;
    setState(
        () => _selectedIds.removeWhere(widget.state.downloadedIds.contains));
    final failures =
        selected.where((clip) => widget.state.isFailedClip(clip.id)).length;
    final galleryFailures = selected
        .where((clip) => widget.state.gallerySaveFailures.containsKey(clip.id))
        .length;
    final message = failures > 0
        ? '$failures ${failures == 1 ? 'download' : 'downloads'} failed. Tap to retry.'
        : galleryFailures > 0
            ? 'Downloaded! Note: $galleryFailures clip${galleryFailures == 1 ? '' : 's'} could not be exported to Photos/Gallery.'
            : 'Download complete. Original files transferred to phone.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.state.active;
    if (active == null) {
      return const EmptyState(
        icon: Icons.desktop_access_disabled,
        title: 'No PC paired',
        message: 'Open Settings to pair a PC.',
      );
    }

    // Sort remote clips newest first
    final clips = List<Clip>.of(widget.state.remoteClips)
      ..sort((a, b) => b.lastWriteTimeUtc.compareTo(a.lastWriteTimeUtc));

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
                  ),
                ),
                SliverToBoxAdapter(
                  child: LibraryHeading(
                    title: 'PC Recordings',
                    detail: '${clips.length} available · Direct Wi-Fi transfer',
                  ),
                ),
                _content(clips),
              ],
            ),
          ),
        ),
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
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.state.activeStatus.availability == DeviceAvailability.offline &&
        widget.state.remoteClips.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.wifi_off,
          title: 'PC is offline',
          message: widget.state.clipLoadError ??
              'Make sure your PC is turned on and connected to the same Wi-Fi network.',
          action: FilledButton.tonal(
            onPressed: widget.state.refreshClips,
            child: const Text('Try Again'),
          ),
        ),
      );
    }
    if (clips.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.check_circle_outline,
          title: 'No recordings on PC',
          message:
              'New game recordings saved on your PC will appear here automatically when finished.',
          action: OutlinedButton.icon(
            onPressed: widget.state.refreshClips,
            icon: const Icon(Icons.refresh),
            label: const Text('Check Again'),
          ),
        ),
      );
    }
    return SliverList.builder(
      itemCount: clips.length,
      itemBuilder: (context, index) {
        final clip = clips[index];
        final selected = _selectedIds.contains(clip.id);
        final isDownloaded = widget.state.downloadedIds.contains(clip.id);
        final isDownloading = widget.state.isDownloadingClip(clip.id);
        final progress = widget.state.getProgress(widget.state.active, clip.id);
        final failure = widget.state.getFailure(widget.state.active, clip.id);

        final downloadedClip = isDownloaded
            ? widget.state.downloadedClips
                .firstWhere((item) => item.id == clip.id)
            : null;
        final canStreamRemotely = !(widget.state.active?.usesTls ?? false);

        return _RemoteClipCard(
          clip: clip,
          loadThumbnail: widget.state.loadThumbnail,
          selected: selected,
          isDownloaded: isDownloaded,
          isDownloading: isDownloading,
          progress: progress,
          failed: failure,
          canStreamRemotely: canStreamRemotely,
          onCancelDownload: () => widget.state.cancelDownload(clip.id),
          onTap: () {
            if (isDownloaded && downloadedClip != null) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen.local(
                    clip: downloadedClip,
                    diagnostics: widget.state.diagnostics,
                  ),
                ),
              );
            } else if (!isDownloading) {
              setState(() {
                if (selected) {
                  _selectedIds.remove(clip.id);
                } else {
                  _selectedIds.add(clip.id);
                }
              });
            }
          },
          onDownloadSingle: () async {
            await widget.state.downloadClips([clip]);
          },
          onPlay: () {
            if (isDownloaded && downloadedClip != null) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen.local(
                    clip: downloadedClip,
                    diagnostics: widget.state.diagnostics,
                  ),
                ),
              );
              return;
            }
            if (!canStreamRemotely) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'This PC uses an encrypted connection. Download the clip to play it on this device.'),
                ),
              );
              return;
            }
            final api = widget.state.api;
            if (api == null) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PlayerScreen.remote(
                  clip: clip,
                  api: api,
                  diagnostics: widget.state.diagnostics,
                ),
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
    required this.isDownloaded,
    required this.isDownloading,
    required this.onTap,
    required this.onDownloadSingle,
    required this.onPlay,
    required this.onCancelDownload,
    this.canStreamRemotely = true,
    this.progress,
    this.failed,
  });

  final Clip clip;
  final Future<Uint8List?> Function(Clip clip) loadThumbnail;
  final bool selected;
  final bool isDownloaded;
  final bool isDownloading;
  final bool canStreamRemotely;
  final double? progress;
  final String? failed;
  final VoidCallback onTap;
  final VoidCallback onDownloadSingle;
  final VoidCallback onPlay;
  final VoidCallback onCancelDownload;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    String? statusMessage;
    if (failed != null) {
      statusMessage = 'Download failed. Tap to retry.';
    } else if (isDownloaded) {
      statusMessage = 'Downloaded · Available offline';
    }

    return RecordingRow(
      preview: Stack(
        fit: StackFit.expand,
        children: [
          _RemoteThumbnail(
            clip: clip,
            loadThumbnail: loadThumbnail,
            selected: selected,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: isDownloaded
                  ? 'Play local clip'
                  : canStreamRemotely
                      ? 'Stream preview from PC'
                      : 'Download to play',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              onPressed: isDownloading ? null : onPlay,
              icon: Icon(
                  isDownloaded ? Icons.play_circle_fill : Icons.play_arrow),
            ),
          ),
        ],
      ),
      fileName: clip.fileName,
      metadata:
          '${formatBytes(clip.sizeBytes)}\n${formatClipDate(clip.lastWriteTimeUtc)}',
      selected: selected,
      downloading: isDownloading,
      progress: progress,
      status: statusMessage,
      onTap: isDownloading ? null : onTap,
      action: isDownloaded
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                avatar: const Icon(Icons.check_circle,
                    size: 16, color: Color(0xFF2E9D59)),
                label: const Text('Downloaded', style: TextStyle(fontSize: 11)),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                backgroundColor: colors.surfaceContainerHigh,
              ),
            )
          : isDownloading
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Cancel download',
                      onPressed: onCancelDownload,
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Download ${clip.fileName}',
                      style: IconButton.styleFrom(
                        backgroundColor: colors.primaryContainer,
                        foregroundColor: colors.onPrimaryContainer,
                      ),
                      onPressed: onDownloadSingle,
                      icon: const Icon(Icons.download, size: 20),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: selected
                          ? 'Deselect ${clip.fileName}'
                          : 'Select ${clip.fileName}',
                      onPressed: onTap,
                      icon: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                      ),
                      color: selected ? colors.primary : colors.outline,
                    ),
                  ],
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
                      .withValues(alpha: 0.13),
                ),
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
                Text(
                  '$count selected',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: busy ? null : onDownload,
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(
                    busy
                        ? 'Downloading…'
                        : 'Download $count ${count == 1 ? 'clip' : 'clips'}',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
