import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shadowplay/app/app.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/models.dart';
import 'package:shadowplay/features/clips/clips_screen.dart';
import 'package:shadowplay/features/player/player_screen.dart';
import 'package:shadowplay/features/settings/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final now = DateTime.now().toUtc();
  final previewVideo = File(
    '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}design-preview.mp4',
  );
  final connection = Connection(
    serverId: 'preview-server',
    computerName: 'GAMING-PC',
    address: '192.168.1.20',
    port: 5177,
    lastSeenUtc: now.subtract(const Duration(minutes: 2)),
  );
  final state = AppState.forTesting(
    preferences,
    connections: [connection],
    activeServerId: connection.serverId,
    onboardingCompleted: true,
    downloadedClips: await previewVideo.exists()
        ? [
            DownloadedClip(
              id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              fileName: 'Valorant_Ace.mp4',
              sizeBytes: await previewVideo.length(),
              lastWriteTimeUtc: now.subtract(const Duration(minutes: 4)),
              localPath: previewVideo.path,
            ),
          ]
        : const [],
    remoteClips: [
      Clip(
        id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        fileName: 'Valorant_Ace.mp4',
        sizeBytes: 184000000,
        lastWriteTimeUtc: now.subtract(const Duration(minutes: 4)),
      ),
      Clip(
        id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        fileName: 'Ranked_Clutch.mp4',
        sizeBytes: 96000000,
        lastWriteTimeUtc: now.subtract(const Duration(hours: 1)),
      ),
      Clip(
        id: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        fileName: 'Match_Highlight.mp4',
        sizeBytes: 242000000,
        lastWriteTimeUtc: now.subtract(const Duration(hours: 3)),
      ),
      Clip(
        id: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        fileName: 'Quick_Scope.mp4',
        sizeBytes: 81000000,
        lastWriteTimeUtc: now.subtract(const Duration(days: 1)),
      ),
    ],
  );
  state.deviceStatuses[connection.serverId] = const DeviceStatus.online();
  state.lastSyncUtc = now.subtract(const Duration(minutes: 2));
  Timer(const Duration(seconds: 2), () async {
    state.deviceStatuses[connection.serverId] = const DeviceStatus.online();
    await state.setNewClipNotifications(state.newClipNotifications);
  });
  const screen = String.fromEnvironment('PREVIEW_SCREEN', defaultValue: 'app');
  runApp(
    screen == 'app'
        ? ShadowPlayApp(state: state)
        : _FocusedPreviewApp(state: state, screen: screen),
  );
}

class _FocusedPreviewApp extends StatelessWidget {
  const _FocusedPreviewApp({required this.state, required this.screen});

  final AppState state;
  final String screen;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF315FD6);
    final scheme = ColorScheme.fromSeed(seedColor: seed);
    final downloaded = state.downloadedClips.firstOrNull;
    final child = switch (screen) {
      'clips' => ClipsScreen(state: state),
      'settings' => SettingsScreen(state: state),
      'player' when downloaded != null => PlayerScreen(clip: downloaded),
      _ => const SizedBox.shrink(),
    };
    if (screen == 'player') {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(scheme),
        home: child,
      );
    }
    final selected = screen == 'settings' ? 2 : 1;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(scheme),
      home: Scaffold(
        body: SafeArea(bottom: false, child: child),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selected,
          onDestinationSelected: (_) {},
          destinations: const [
            NavigationDestination(
                icon: Icon(Icons.home_outlined), label: 'Home'),
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              label: 'Clips',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  ThemeData _theme(ColorScheme scheme) => ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        navigationBarTheme: NavigationBarThemeData(
          height: 72,
          indicatorColor: scheme.secondaryContainer,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(64, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );
}
