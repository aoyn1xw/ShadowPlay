import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_state.dart';
import '../../core/models.dart';
import '../../shared/widgets.dart';
import '../../shared/recording_row.dart';
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
              title: 'ShadowPlay',
            ),
          ),
          SliverToBoxAdapter(
              child: LibraryHeading(
            title: 'Downloaded clips',
            detail:
                '${state.downloadedClips.length} on this phone · Available offline',
          )),
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
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => PlayerScreen.local(clip: clip)),
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
        action: IconButton(
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
