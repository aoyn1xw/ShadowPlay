import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadowplay/app/app.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/models.dart';
import 'package:shadowplay/features/clips/clips_screen.dart';
import 'package:shadowplay/shared/recording_row.dart';

const _capture = bool.fromEnvironment('UI_REVIEW');
final _boundary = GlobalKey();

Future<void> capture(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 300));
  if (!_capture) return;
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../docs/ui-review/flutter/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<AppState> sampleState({bool onboarding = false}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final pc = Connection(
      serverId: 'sample-pc',
      computerName: 'GAMING-PC',
      address: '192.168.1.20',
      port: 5177);
  final state = AppState.forTesting(prefs,
      connections: onboarding ? [] : [pc],
      activeServerId: onboarding ? null : pc.serverId,
      onboardingCompleted: !onboarding,
      remoteClips: [
        for (var i = 0; i < 4; i++)
          Clip(
              id: 'sample-$i',
              fileName: [
                'Valorant_Ace.mp4',
                'Ranked_Clutch.mp4',
                'Counter-Strike 2 — overtime recording.mp4',
                'Long recording filename with spaces and details.mp4'
              ][i],
              sizeBytes: 184000000 + i * 10000000,
              lastWriteTimeUtc: DateTime.utc(2026, 9, 4, 18, 30),
              duration: const Duration(seconds: 92)),
      ]);
  state.deviceStatuses[pc.serverId] = const DeviceStatus.online();
  return state;
}

Future<void> mount(
    WidgetTester tester, AppState state, Size size, double scale) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
      RepaintBoundary(key: _boundary, child: ShadowPlayApp(state: state)));
  await tester.pump();
}

void main() {
  setUpAll(() async {
    if (_capture) {
      const path = String.fromEnvironment('UI_REVIEW_FONT');
      if (path.isNotEmpty) {
        final bytes = ByteData.sublistView(await File(path).readAsBytes());
        for (final family in ['Roboto', 'Ahem']) {
          await (FontLoader(family)..addFont(Future.value(bytes))).load();
        }
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
      }
    }
  });

  for (final dark in [false, true]) {
    testWidgets(
        'phone library selection, progress, errors and settings ${dark ? 'dark' : 'light'}',
        (tester) async {
      final state = await sampleState();
      state.themeMode = dark ? ThemeMode.dark : ThemeMode.light;
      await mount(tester, state, const Size(390, 844), 1);
      await capture(tester, 'home-empty-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text('Clips'));
      await tester.pump();
      expect(find.byType(RecordingRow), findsWidgets);
      await capture(tester, 'clips-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text('Valorant_Ace.mp4'));
      await tester.pump();
      expect(find.text('Download 1 clip'), findsOneWidget);
      await capture(tester, 'selected-${dark ? 'dark' : 'light'}');
      state.downloadProgress['sample-0'] = 0.42;
      state.downloadFailures['sample-1'] = 'Connection interrupted';
      await tester.pumpWidget(
          RepaintBoundary(key: _boundary, child: ShadowPlayApp(state: state)));
      await tester.pump();
      expect(find.text('Downloading 42%'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Downloading…'))
              .onPressed,
          isNull);
      await capture(tester, 'transfer-${dark ? 'dark' : 'light'}');
      await tester.tap(find.text('Settings').last);
      await tester.pump();
      await capture(tester, 'settings-${dark ? 'dark' : 'light'}');
      await tester.scrollUntilVisible(find.text('Theme'), 220,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('Theme'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(dark ? 'Light' : 'Dark').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(state.themeMode, dark ? ThemeMode.light : ThemeMode.dark);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets('downloaded library retains gallery retry and local player error',
      (tester) async {
    final state = await sampleState();
    state.themeMode = ThemeMode.light;
    state.downloadedClips = [
      DownloadedClip(
          id: 'local-sample',
          fileName: 'Downloaded_recording.mp4',
          sizeBytes: 96000000,
          lastWriteTimeUtc: DateTime.utc(2026, 9, 4),
          localPath: 'missing-review-recording.mp4',
          duration: const Duration(seconds: 45))
    ];
    state.gallerySaveFailures['local-sample'] = 'Gallery unavailable';
    await mount(tester, state, const Size(390, 844), 1);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Save to Photos/Gallery'), findsOneWidget);
    expect(find.text('Gallery save failed. Use the save button to retry.'),
        findsOneWidget);
    await capture(tester, 'home-gallery-retry');
    await tester.tap(find.text('Downloaded_recording.mp4'));
    await tester.pumpAndSettle();
    expect(find.text('Cannot play this clip'), findsOneWidget);
    final errorContext = tester.element(find.text('Cannot play this clip'));
    expect(Theme.of(errorContext).colorScheme.brightness, Brightness.dark);
    await capture(tester, 'player-error-light-app');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Downloaded clips'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('offline recovery and loading remain visible at large text',
      (tester) async {
    final state = await sampleState();
    state.remoteClips = [];
    await mount(tester, state, const Size(320, 568), 2);
    state.deviceStatuses['sample-pc'] =
        const DeviceStatus.offline('PC is asleep');
    await tester.pumpWidget(
        RepaintBoundary(key: _boundary, child: ShadowPlayApp(state: state)));
    await tester.tap(find.text('Clips'));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('Try Again'), 160,
        scrollable: find.byType(Scrollable).last);
    await tester.pump();
    expect(find.text('PC is offline'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'offline-large-text');
    await tester.pumpWidget(const SizedBox());
    state.clipsLoading = true;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ClipsScreen(state: state))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  for (final size in [const Size(320, 568), const Size(844, 390)]) {
    testWidgets('onboarding and library fit $size at 200 percent text',
        (tester) async {
      final intro = await sampleState(onboarding: true);
      await mount(tester, intro, size, 2);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Continue'), 180,
          scrollable: find.byType(Scrollable).last);
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture(tester, 'permissions-${size.width.toInt()}-large-text');
      await tester.scrollUntilVisible(find.text('Continue'), 180,
          scrollable: find.byType(Scrollable).last);
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Manual Mode'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Device name'), 180,
          scrollable: find.byType(Scrollable).last);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      intro.dispose();

      final state = await sampleState();
      await mount(tester, state, size, 2);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Clips'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Valorant_Ace.mp4'), 180,
          scrollable: find.byType(Scrollable).last);
      await tester.pump();
      await tester.tap(find.text('Valorant_Ace.mp4'));
      await tester.pump();
      expect(find.byType(SelectionActionBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'clips-${size.width.toInt()}-large-text');
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
}
