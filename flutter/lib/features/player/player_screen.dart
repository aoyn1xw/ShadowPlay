import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../core/models.dart';
import '../../shared/widgets.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({required this.clip, super.key});
  final DownloadedClip clip;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialized;
  bool _fullscreen = false;
  bool _listenerAttached = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.clip.localPath));
    _initialized = _controller.initialize().then((_) {
      if (!mounted) return;
      _controller.addListener(_videoChanged);
      _listenerAttached = true;
      setState(() {});
    });
  }

  void _videoChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    if (_fullscreen) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await _restoreOrientation();
    }
    if (mounted) setState(() {});
  }

  Future<void> _restoreOrientation() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  void dispose() {
    if (_listenerAttached) _controller.removeListener(_videoChanged);
    _controller.dispose();
    _restoreOrientation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: _fullscreen
            ? null
            : AppBar(
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                title: Text(widget.clip.fileName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
        body: FutureBuilder<void>(
          future: _initialized,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: EmptyState(
                  icon: Icons.broken_image_outlined,
                  title: 'Cannot play this clip',
                  message: 'The downloaded file may be missing or unsupported.',
                ),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final duration = _controller.value.duration;
            final position = _controller.value.position;
            return SafeArea(
              top: !_fullscreen,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _controller.value.aspectRatio,
                          child: VideoPlayer(_controller),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
                      child: Row(
                        children: [
                          IconButton.filledTonal(
                            tooltip:
                                _controller.value.isPlaying ? 'Pause' : 'Play',
                            onPressed: () => _controller.value.isPlaying
                                ? _controller.pause()
                                : _controller.play(),
                            icon: Icon(_controller.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow),
                          ),
                          Expanded(
                            child: Slider(
                              value: position.inMilliseconds
                                  .clamp(0, duration.inMilliseconds)
                                  .toDouble(),
                              max: duration.inMilliseconds <= 0
                                  ? 1
                                  : duration.inMilliseconds.toDouble(),
                              onChanged: (value) => _controller.seekTo(
                                  Duration(milliseconds: value.round())),
                            ),
                          ),
                          Text(
                            '${formatDuration(position)} / ${formatDuration(duration)}',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                          ),
                          IconButton(
                            tooltip:
                                _fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                            onPressed: _toggleFullscreen,
                            color: Colors.white,
                            icon: Icon(_fullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
}
