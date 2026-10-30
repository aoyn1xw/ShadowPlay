import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../shared/widgets.dart';
import '../../shared/recording_row.dart';
import '../player/player_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.state,
    this.onViewRecordings,
    super.key,
  });

  final AppState state;
  final VoidCallback? onViewRecordings;

  @override
  Widget build(BuildContext context) {
    final active = state.active;
    if (active == null) {
      return const EmptyState(
        icon: Icons.desktop_access_disabled,
        title: 'No PC paired',
        message: 'Pair a PC from Settings to sync clips.',
      );
    }
    return RefreshIndicator(
      onRefresh: state.refreshClips,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: DeviceHeader(
              connection: active,
              status: state.activeStatus,
              lastSyncUtc: state.lastSyncUtc,
              title: 'ShadowPlay',
            ),
          ),
          SliverToBoxAdapter(
            child: _NewRecordingsCard(
              newCount: state.newClipCount,
              pcName: active.computerName,
              onViewRecordings: onViewRecordings,
            ),
          ),
          SliverToBoxAdapter(
            child: LibraryHeading(
              title: 'Downloaded clips',
              detail:
                  '${state.downloadedClips.length} on this phone · Available offline',
            ),
          ),
          if (state.downloadedClips.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.video_library_outlined,
                title: 'No downloaded clips',
                message:
                    'Recordings you download from the Clips tab will appear here for offline playback.',
                action: onViewRecordings == null
                    ? null
                    : OutlinedButton.icon(
                        onPressed: onViewRecordings,
                        icon: const Icon(Icons.video_library_outlined),
                        label: const Text('View Recordings'),
                      ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.only(bottom: 24),
              sliver: SliverList.builder(
                itemCount: state.downloadedClips.length,
                itemBuilder: (context, index) {
                  final clip = state.downloadedClips[index];
                  return _DownloadedClipCard(
                    clip: clip,
                    gallerySaved: state.gallerySavedIds.contains(clip.id),
                    galleryFailure: state.gallerySaveFailures[clip.id],
                    onSave: () async {
                      final saved = await state.saveClipToGallery(clip);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(saved
                              ? 'Clip saved to Photos/Gallery.'
                              : state.gallerySaveFailures[clip.id] ??
                                  'Could not save the clip to Photos/Gallery.'),
                        ),
                      );
                    },
                    onShare: () => _shareClip(context, clip),
                    onDelete: () => _confirmDeleteLocalCopy(
                      context,
                      clip,
                      state,
                      active.computerName,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PlayerScreen.local(
                          clip: clip,
                          diagnostics: state.diagnostics,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  static Future<void> _shareClip(
      BuildContext context, DownloadedClip clip) async {
    final file = File(clip.localPath);
    if (!await file.exists()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Local file not found on device.')),
      );
      return;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(clip.localPath)],
        text: clip.fileName,
      ),
    );
  }

  static Future<void> _confirmDeleteLocalCopy(
    BuildContext context,
    DownloadedClip clip,
    AppState state,
    String pcName,
  ) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete local copy?'),
            content: Text(
              'This removes "${clip.fileName}" from this phone.\n\n'
              'The original recording remains safe on $pcName.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(dialogContext).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (confirmed) {
      await state.deleteDownloadedClip(clip);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Local copy deleted. The original recording remains on your PC.'),
        ),
      );
    }
  }
}

class _NewRecordingsCard extends StatelessWidget {
  const _NewRecordingsCard({
    required this.newCount,
    required this.pcName,
    this.onViewRecordings,
  });

  final int newCount;
  final String pcName;
  final VoidCallback? onViewRecordings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasNew = newCount > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Card(
        elevation: 0,
        color: colors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: hasNew
                ? colors.primary.withValues(alpha: 0.5)
                : colors.outlineVariant,
            width: hasNew ? 1.5 : 0.5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isConstrained = constraints.maxWidth < 340 ||
                  MediaQuery.textScalerOf(context).scale(14) > 18;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: hasNew
                              ? colors.primaryContainer
                              : colors.surfaceContainerHigh,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          hasNew
                              ? Icons.video_library
                              : Icons.check_circle_outline,
                          color:
                              hasNew ? colors.primary : colors.onSurfaceVariant,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasNew
                                  ? '$newCount new recording${newCount == 1 ? '' : 's'} available'
                                  : 'No new recordings',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasNew
                                  ? 'Ready to download from $pcName over Wi-Fi.'
                                  : 'All recordings on $pcName are up to date.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (isConstrained) ...[
                    Text(
                      'Direct Wi-Fi transfer · Original quality',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: onViewRecordings,
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: const Text('View recordings'),
                      ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Direct Wi-Fi transfer · Original quality',
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: onViewRecordings,
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          label: const Text('View recordings'),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DownloadedClipCard extends StatelessWidget {
  const _DownloadedClipCard({
    required this.clip,
    required this.onTap,
    required this.onSave,
    required this.onShare,
    required this.onDelete,
    required this.gallerySaved,
    this.galleryFailure,
  });

  final DownloadedClip clip;
  final VoidCallback onTap;
  final Future<void> Function() onSave;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final bool gallerySaved;
  final String? galleryFailure;

  @override
  Widget build(BuildContext context) => RecordingRow(
        preview:
            _LocalVideoPreview(path: clip.localPath, duration: clip.duration),
        fileName: clip.fileName,
        metadata:
            '${formatBytes(clip.sizeBytes)}\n${formatClipDate(clip.lastWriteTimeUtc)}',
        status: galleryFailure == null
            ? null
            : 'Gallery save failed. Use the save button to retry.',
        onTap: onTap,
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: gallerySaved
                  ? 'Saved to Photos/Gallery'
                  : 'Save to Photos/Gallery',
              onPressed: gallerySaved ? null : () => onSave(),
              icon: Icon(
                gallerySaved
                    ? Icons.check
                    : galleryFailure == null
                        ? Icons.save_alt
                        : Icons.warning_amber_rounded,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'More actions',
              icon: const Icon(Icons.more_vert),
              onSelected: (value) {
                if (value == 'share') onShare();
                if (value == 'delete') onDelete();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'share',
                  child: Row(
                    children: [
                      Icon(Icons.share_outlined),
                      SizedBox(width: 8),
                      Expanded(child: Text('Share clip')),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.redAccent),
                      SizedBox(width: 8),
                      Expanded(child: Text('Delete local copy')),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _LocalVideoPreview extends StatefulWidget {
  const _LocalVideoPreview({required this.path, this.duration});
  final String path;
  final Duration? duration;

  @override
  State<_LocalVideoPreview> createState() => _LocalVideoPreviewState();
}

class _LocalVideoPreviewState extends State<_LocalVideoPreview> {
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final controller = VideoPlayerController.file(File(widget.path));
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.pause();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      await controller.dispose();
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void didUpdateWidget(covariant _LocalVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _controller?.dispose();
      _controller = null;
      _error = null;
      _initialize();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || _error != null) {
      return ClipPoster(
          badge: widget.duration != null
              ? formatDuration(widget.duration!)
              : _error == null
                  ? 'Loading'
                  : 'Video');
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: ui.Clip.hardEdge,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          ),
        ),
        Positioned(
          left: 8,
          top: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(20)),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: Icon(Icons.play_arrow, color: Colors.white, size: 18),
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
                color: Colors.black87, borderRadius: BorderRadius.circular(6)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                formatDuration(controller.value.duration),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
