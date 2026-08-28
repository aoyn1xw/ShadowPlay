import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shadowplay/app/app.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/models.dart';
import 'package:shadowplay/features/clips/clips_screen.dart';
import 'package:shadowplay/features/shell/main_shell.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('first run explains camera access before exposing the scanner',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final state = AppState.forTesting(preferences);
    await tester.pumpWidget(ShadowPlayApp(state: state));

    expect(find.text('Get Started'), findsOneWidget);
    expect(find.text('Open Camera'), findsNothing);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Allow Camera'), findsOneWidget);
    expect(find.text('Open Camera'), findsNothing);

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Scan QR Code'), findsOneWidget);
    expect(find.text('Manual Mode'), findsOneWidget);
    expect(find.text('Open Camera'), findsOneWidget);

    await tester.tap(find.text('Manual Mode'));
    await tester.pumpAndSettle();
    expect(find.text('PC address'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Pairing code'), findsOneWidget);
    expect(find.text('Device name'), findsOneWidget);
    expect(find.text('Pair Device'), findsOneWidget);
  });

  testWidgets('main shell has exactly Home Clips and Settings destinations',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final state = AppState.forTesting(preferences);
    await tester.pumpWidget(MaterialApp(home: MainShell(state: state)));
    await tester.pump();

    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Clips'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('selection action uses singular and plural download labels',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionActionBar(count: 1, busy: false, onDownload: () {}),
        ),
      ),
    );
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Download 1 clip'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionActionBar(count: 3, busy: false, onDownload: () {}),
        ),
      ),
    );
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.text('Download 3 clips'), findsOneWidget);
  });

  testWidgets('Clips grid supports multi-selection inside the real shell',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final connection = Connection(
      serverId: 'server-1',
      computerName: 'GAMING-PC',
      address: '192.168.1.20',
      port: 5177,
    );
    final state = AppState.forTesting(
      preferences,
      connections: [connection],
      activeServerId: connection.serverId,
      onboardingCompleted: true,
      remoteClips: [
        Clip(
          id: List.filled(64, 'a').join(),
          fileName: 'Valorant_Ace.mp4',
          sizeBytes: 184000000,
          lastWriteTimeUtc: DateTime.utc(2026, 8, 28, 14, 30),
        ),
        Clip(
          id: List.filled(64, 'b').join(),
          fileName: 'Ranked_Clutch.mp4',
          sizeBytes: 96000000,
          lastWriteTimeUtc: DateTime.utc(2026, 8, 28, 13, 30),
        ),
      ],
    );
    state.deviceStatuses[connection.serverId] = const DeviceStatus.online();

    await tester.pumpWidget(MaterialApp(home: MainShell(state: state)));
    await tester.pump();
    await tester.tap(find.text('Clips'));
    await tester.pump();

    await tester.tap(find.text('Valorant_Ace.mp4'));
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Download 1 clip'), findsOneWidget);

    await tester.ensureVisible(find.text('Ranked_Clutch.mp4'));
    await tester.pump();
    await tester.tap(find.text('Ranked_Clutch.mp4'));
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('Download 2 clips'), findsOneWidget);
  });

  testWidgets('Settings exposes the requested grouped controls',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final state = AppState.forTesting(preferences);
    await tester.pumpWidget(MaterialApp(home: MainShell(state: state)));
    await tester.pump();
    await tester.tap(find.text('Settings'));
    await tester.pump();

    expect(find.text('PAIRED DEVICES'), findsOneWidget);
    expect(find.text('Pair a New Device'), findsOneWidget);
    expect(find.text('DOWNLOADS / STORAGE'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('APPEARANCE / APP'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);
  });
}
