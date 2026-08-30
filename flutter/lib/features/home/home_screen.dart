import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../shared/widgets.dart';
import '../player/player_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.state, super.key});

  final AppState state;

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
              welcome: true,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
              child: Text(
                'Downloaded clips',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          if (state.downloadedClips.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.video_library_outlined,
                title: 'No downloaded clips',
                message:
                    'Choose clips from the Clips tab. Downloads appear here for offline playback.',
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverGrid.builder(
                itemCount: state.downloadedClips.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.82,
                ),
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
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => PlayerScreen(clip: clip)),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _DownloadedClipCard extends StatelessWidget {
  const _DownloadedClipCard({
    required this.clip,
    required this.onTap,
    required this.onSave,
    required this.gallerySaved,
    this.galleryFailure,
  });
  final DownloadedClip clip;
  final VoidCallback onTap;
  final Future<void> Function() onSave;
  final bool gallerySaved;
  final String? galleryFailure;

  @override
  Widget build(BuildContext context) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        clipBehavior: ui.Clip.antiAlias,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _LocalVideoPreview(path: clip.localPath),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: IconButton.filledTonal(
                        tooltip: gallerySaved
                            ? 'Saved to Photos/Gallery'
                            : 'Save to Photos/Gallery',
                        onPressed: gallerySaved
                            ? null
                            : () {
                                onSave();
                              },
                        icon: Icon(gallerySaved
                            ? Icons.check
                            : galleryFailure == null
                                ? Icons.save_alt
                                : Icons.warning_amber_rounded),
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
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 11),
                child: Text(
                  formatClipDate(clip.lastWriteTimeUtc),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _LocalVideoPreview extends StatefulWidget {
  const _LocalVideoPreview({required this.path});
  final String path;

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
      return ClipPoster(badge: _error == null ? 'Loading' : 'Video');
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
