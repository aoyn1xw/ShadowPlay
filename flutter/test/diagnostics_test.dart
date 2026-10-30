import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/diagnostics.dart';
import 'package:shadowplay/features/settings/diagnostics_screen.dart';

/// Tests for the local diagnostics logger: redaction guarantees, verbose vs
/// normal modes, rotating file storage under a bounded budget, export report
/// behavior, and the AppState/Diagnostics screen integration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DiagnosticEntry entryWith({
    String message = 'message',
    Map<String, Object?>? context,
  }) =>
      DiagnosticEntry.create(
        timeUtc: DateTime.utc(2026, 1, 1, 12),
        severity: DiagnosticSeverity.info,
        component: 'test',
        message: message,
        context: context,
      );

  group('redaction of secrets and private paths', () {
    test('drops bearer tokens from free text', () {
      final result = redact(
          'Auth failure for Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload');
      expect(result, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(result, contains('Bearer ●●●'));
      expect(result, contains('Auth failure for'));
    });

    test('drops authorization header values in JSON form', () {
      final result =
          redact('sent {"authorization": "abcdef1234567890"} to device');
      expect(result, isNot(contains('abcdef1234567890')));
      expect(result, contains('"authorization": "●●●'));
    });

    test('drops proxy authorization values', () {
      final result = redact(
        '"proxy-authorization": "s3cr3tHeaderValue99"',
      );
      expect(result, isNot(contains('s3cr3tHeaderValue99')));
    });

    test('drops pairing codes in key=value form', () {
      final result = redact('enter pairing code: ABCW123XYZ9 on the PC');
      expect(result, contains('pairing code: ●●●'));
      expect(result, isNot(contains('ABCW123XYZ9')));
    });

    test('drops bare token JSON values without a prefix word', () {
      final result = redact('handled reply {"token": "abcdef123456"}');
      expect(result, isNot(contains('abcdef123456')));
    });

    test('replaces PEM blocks with a placeholder', () {
      final message = 'cert check:\n-----BEGIN PRIVATE KEY-----\n'
          'MIGHAgEAMBMGByqGSM49AgEGCC\n-----END PRIVATE KEY-----\n';
      final result = redact(message);
      expect(result, isNot(contains('MIGHAgEAMBM')));
      expect(result, contains('●●● key or certificate ●●●'));
    });

    test('keeps only the basename of Windows private paths', () {
      final result =
          redact(r'read error at C:\Users\ayon\AppData\Local\vendor\clip.mp4');
      expect(result, contains('…/clip.mp4'));
      expect(result, isNot(contains('ayon')));
      expect(result, isNot(contains('AppData')));
    });

    test('keeps only the basename of POSIX private paths', () {
      final result =
          redact('read error at /data/data/com.ayon1xw.shadowplay/files/'
              'clip-42.mp4');
      expect(result, contains('…/clip-42.mp4'));
      expect(result, isNot(contains('com.ayon1xw')));
      expect(result, isNot(contains('home')));
    });

    test('leaves API paths untouched', () {
      const request = 'GET /api/v1/clips returned 8 items';
      expect(redact(request), request);
    });

    test('screens sensitive context keys entirely', () {
      final entry = entryWith(context: {
        'authorization': 'Bearer abcdef123456',
        'token': 'abcdef123456',
        'pairing-code': 'ABCD1234EFGH',
        'errorCode': 'E4999',
        'port': 1234,
      });
      expect(entry.context['authorization'], '●●●');
      expect(entry.context['token'], '●●●');
      expect(entry.context['pairing-code'], '●●●');
      expect(entry.context['errorCode'], 'E4999');
      expect(entry.context['port'], '1234');
    });
  });

  group('DiagnosticEntry', () {
    test('keeps short components, falls back for odd ones', () {
      expect(entryWith().component, 'test');
      final empty = DiagnosticEntry.create(
        timeUtc: DateTime.utc(2026),
        severity: DiagnosticSeverity.error,
        component: '   ',
        message: 'm',
      );
      expect(empty.component, 'app');
      final long = DiagnosticEntry.create(
        timeUtc: DateTime.utc(2026),
        severity: DiagnosticSeverity.warning,
        component: 'x' * 40,
        message: 'm',
      );
      expect(long.component, 'app');
    });

    test('truncates huge messages', () {
      final entry = entryWith(message: 'x' * 5000);
      expect(entry.message.length, lessThanOrEqualTo(1601));
      expect(entry.message.endsWith('…'), isTrue);
    });

    test('encodes to one JSON line and parses back', () {
      final entry = entryWith(
        message: 'clip finished',
        context: {'fileName': 'rec-1.mp4', 'size': 5120},
      );
      final line = entry.encode();
      expect(line.contains('\n'), isFalse);
      final parsed = DiagnosticEntry.tryParse(line);
      expect(parsed, isNotNull);
      expect(parsed!.severity, DiagnosticSeverity.info);
      expect(parsed.component, 'test');
      expect(parsed.message, 'clip finished');
      expect(parsed.context['fileName'], 'rec-1.mp4');
    });

    test('skips corrupt or unknown lines instead of throwing', () {
      expect(DiagnosticEntry.tryParse('not json'), isNull);
      expect(
        DiagnosticEntry.tryParse('{"lv":"verbose","ts":"2026-01-01T00:00:00Z",'
            '"c":"a","m":"m"}'),
        isNull,
      );
      expect(
        DiagnosticEntry.tryParse(
            '{"lv":"info","ts":"garbage","c":"a","m":"m"}'),
        isNull,
      );
      expect(DiagnosticEntry.tryParse(''), isNull);
    });
  });

  group('verbose and normal diagnostic modes', () {
    test('normal mode suppresses debug events', () {
      final diag = Diagnostics();
      diag.debug('player', 'should not appear');
      diag.info('player', 'should appear');
      diag.warning('player', 'warning appears');
      diag.error('player', 'error appears');
      expect(diag.inMemoryCount, 3);
      final messages = diag.recent().map((entry) => entry.message).toList();
      expect(
          messages, containsAll(<String>['should appear', 'warning appears']));
      expect(messages, isNot(contains('should not appear')));
      expect(diag.verbose, isFalse);
    });

    test('verbose mode records debug events and the toggle itself', () {
      final diag = Diagnostics();
      diag.applyVerbose(true);
      diag.debug('player', 'now visible');
      final messages = diag.recent().map((entry) => entry.message).toList();
      expect(messages.first, 'now visible');
      expect(messages, contains('Verbose diagnostics enabled'));
      expect(diag.verbose, isTrue);
    });

    test('setting the same verbosity again records no event', () {
      final diag = Diagnostics();
      diag.applyVerbose(true);
      diag.applyVerbose(true);
      expect(
        diag
            .recent()
            .where((entry) => entry.message == 'Verbose diagnostics enabled')
            .length,
        1,
      );
    });
  });

  group('rotating file storage', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('shadowplay-diag-test-');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('entries are written to the app-private directory', () async {
      final diag = Diagnostics();
      expect(diag.attached, isFalse);
      diag.info('storage', 'first');
      diag.warning('storage', 'second');
      // attach() must flush pre-attach entries into the fresh file.
      await diag.attach(temp);
      expect(diag.attached, isTrue);
      await diag.flush();
      final text = await diag.currentFile.readAsString();
      expect(text, contains('"m":"first"'));
      expect(text, contains('"m":"second"'));
      expect(diag.writeFailures, 0);
    });

    test('rotation keeps storage bounded and keeps ordering', () async {
      final diag = Diagnostics();
      await diag.attach(temp, maxTotalBytes: 16 * 1024);
      expect(diag.maxTotalBytes, 16 * 1024);
      for (var i = 0; i < 140; i++) {
        diag.info('rotation', 'entry-${i.toString().padLeft(3, '0')}');
      }
      await diag.flush();

      final current = diag.currentFile;
      final archive = diag.archiveFile;
      expect(archive.existsSync(), isTrue);
      expect(diag.storageBytes, lessThanOrEqualTo(diag.maxTotalBytes + 4096));
      final perFile = diag.maxTotalBytes ~/ 2;
      expect(archive.lengthSync(), lessThanOrEqualTo(perFile + 4096));
      expect(current.lengthSync(), lessThanOrEqualTo(perFile + 4096));

      int indexIn(DiagnosticEntry entry) =>
          int.parse(entry.message.split('-').last);
      final archiveIds = (await linesOf(archive))
          .map(DiagnosticEntry.tryParse)
          .whereType<DiagnosticEntry>()
          .map(indexIn)
          .toList();
      final currentIds = (await linesOf(current))
          .map(DiagnosticEntry.tryParse)
          .whereType<DiagnosticEntry>()
          .map(indexIn)
          .toList();
      expect(archiveIds, isNotEmpty);
      expect(currentIds, isNotEmpty);
      // Older entries live in the archive; newer ones in the current file.
      expect(currentIds.reduce((a, b) => a < b ? a : b),
          greaterThan(archiveIds.reduce((a, b) => a > b ? a : b)));
    });

    test('a restart restores the recent tail into memory', () async {
      final beforeAttach = Diagnostics();
      await beforeAttach.attach(temp);
      beforeAttach.info('restart', 'message-from-before-the-restart');
      await beforeAttach.flush();

      // A brand new instance reading the same directory simulates a restart.
      final after = Diagnostics();
      await after.attach(temp);
      final messages = after.recent().map((entry) => entry.message).toList();
      expect(messages, contains('message-from-before-the-restart'));
    });

    test('clear erases files and logging continues from scratch', () async {
      final diag = Diagnostics();
      await diag.attach(temp);
      diag.info('clear', 'old event that must be erased');
      await diag.flush();
      expect(diag.storageBytes, greaterThan(0));

      await diag.clear();

      expect(diag.currentFile.existsSync(), isTrue); // holds the clear event
      expect(diag.recent().map((entry) => entry.message),
          ['Diagnostic logs cleared']);
      diag.info('clear', 'survivor');
      await diag.flush();
      final text = await diag.currentFile.readAsString();
      expect(text, contains('Diagnostic logs cleared'));
      expect(text, contains('survivor'));
      expect(text, isNot(contains('old event that must be erased')));
    });

    test('write failures are counted and never thrown', () async {
      final sub = Directory('${temp.path}${Platform.pathSeparator}gone');
      final diag = Diagnostics();
      await diag.attach(sub);
      diag.info('failure', 'first ok');
      await diag.flush();
      expect(diag.writeFailures, 0);

      // Deleting the storage directory makes every write attempt fail; the
      // service must count it and carry on rather than crash.
      await sub.delete(recursive: true);
      diag.info('failure', 'into the void');
      await diag.flush();
      expect(diag.writeFailures, greaterThan(0));
      expect(diag.lastWriteError, isNotNull);
      expect(diag.recent().first.message, 'into the void');
    });

    test('attachDefault falls back to memory-only when storage is missing',
        () async {
      final diag = Diagnostics();
      await diag.attachDefault();
      // flutter tests have no path_provider implementation: the service must
      // degrade to memory-only rather than crash or lose events.
      expect(diag.attached, isFalse);
      diag.info('fallback', 'kept in memory');
      expect(diag.recent().first.message, 'kept in memory');
      final path = await diag.exportReport();
      final text = await File(path).readAsString();
      expect(text, contains('== In-memory session events =='));
    });
  });

  group('diagnostics export report', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('shadowplay-diag-test-');
    });

    tearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<String> exportAndRead(Diagnostics diag) async {
      final path = await diag.exportReport();
      final file = File(path);
      final dir = file.parent;
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      return file.readAsString();
    }

    test('attached export contains the header and stored events', () async {
      final diag = Diagnostics();
      await diag.attach(temp);
      diag.info('export', 'exported-event-67', {'fileName': 'clip.mp4'});
      await diag.flush();
      final report = await exportAndRead(diag);
      expect(report, startsWith('ShadowPlay Diagnostics Report'));
      expect(report, contains('verbose mode: false'));
      expect(report, contains('== Current log file =='));
      expect(report, contains('"m":"exported-event-67"'));
      expect(report, contains('Logs stay on this device'));
      // Long-running sessions rotate: the previous file lands in the report.
      expect(report.contains('== Previous log file =='),
          diag.archiveFile.existsSync());
    });

    test('memory-only export contains session events and privacy note',
        () async {
      final diag = Diagnostics();
      diag.info('export', 'memory-only-event-91');
      final report = await exportAndRead(diag);
      expect(report, contains('file storage unavailable'));
      expect(report, contains('"m":"memory-only-event-91"'));
      expect(report, startsWith('ShadowPlay Diagnostics Report'));
    });

    test('high-frame-rate Photos export reports are appended', () async {
      final hfr = Directory(
          '${temp.path}${Platform.pathSeparator}ShadowPlayDiagnostics')
        ..createSync(recursive: true);
      File('${hfr.path}${Platform.pathSeparator}hfr-new.txt')
          .writeAsStringSync('source duration 12.34s output duration 12.34s');
      final older = File('${hfr.path}${Platform.pathSeparator}hfr-old.txt')
        ..writeAsStringSync('older hfr artifact content');
      File('${hfr.path}${Platform.pathSeparator}notes.dat')
          .writeAsStringSync('must never appear');
      // 'newer' keeps its default recent timestamp; age the other one.
      older.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 2)));

      final report = StringBuffer();
      final diag = Diagnostics();
      await diag.appendHighFrameRateReports(report, temp.path);
      final text = report.toString();
      expect(text,
          contains('== High-frame-rate Photos export diagnostics (iOS) =='));
      expect(text, contains('-- hfr-new.txt'));
      expect(text, contains('source duration 12.34s'));
      expect(text, contains('hfr-old.txt'));
      expect(text, isNot(contains('must never appear')));
      // Newest first.
      expect(
          text.indexOf('hfr-new.txt'), lessThan(text.indexOf('hfr-old.txt')));
    });

    test('missing high-frame-rate directory adds nothing', () async {
      final report = StringBuffer();
      final diag = Diagnostics();
      await diag.appendHighFrameRateReports(
          report, '${temp.path}${Platform.pathSeparator}no-such-dir');
      expect(report.isEmpty, isTrue);
    });
  });

  group('AppState diagnostics integration', () {
    test('verbose toggle persists and records an event', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final diag = Diagnostics();
      final state = AppState.forTesting(prefs, diagnostics: diag);
      expect(state.isVerboseDiagnostics, isFalse);
      expect(diag.verbose, isFalse);

      await state.setVerboseDiagnostics(true);
      expect(state.isVerboseDiagnostics, isTrue);
      expect(prefs.getBool('diagnosticsVerbose'), isTrue);
      expect(diag.verbose, isTrue);
      expect(diag.recent().first.message, 'Verbose diagnostics enabled');

      await state.setVerboseDiagnostics(false);
      expect(prefs.getBool('diagnosticsVerbose'), isFalse);
      expect(diag.verbose, isFalse);
      expect(diag.recent().first.message, 'Verbose diagnostics disabled');
    });

    test('state lifecycle events reach the diagnostics log', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final diag = Diagnostics();
      final state = AppState.forTesting(prefs, diagnostics: diag);

      await state.completeOnboarding();
      final messages = diag.recent().map((entry) => entry.message).toList();
      expect(messages, contains('Onboarding completed'));
    });
  });

  group('DiagnosticsScreen', () {
    Future<AppState> testingState(Diagnostics diag) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      return AppState.forTesting(prefs, diagnostics: diag);
    }

    testWidgets('lists events newest first and shows details', (tester) async {
      final diag = Diagnostics();
      diag.info('player', 'oldest-ui-event');
      diag.warning('player', 'newest-ui-event');
      final state = await testingState(diag);

      await tester
          .pumpWidget(MaterialApp(home: DiagnosticsScreen(state: state)));

      expect(find.text('oldest-ui-event'), findsOneWidget);
      expect(find.text('newest-ui-event'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('newest-ui-event')).dy,
        lessThan(tester.getTopLeft(find.text('oldest-ui-event')).dy),
      );

      await tester.tap(find.text('newest-ui-event'));
      await tester.pumpAndSettle();
      expect(find.text('Event details'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });

    testWidgets('empty log shows the empty state', (tester) async {
      final state = await testingState(Diagnostics());
      await tester
          .pumpWidget(MaterialApp(home: DiagnosticsScreen(state: state)));
      expect(find.text('No events yet'), findsOneWidget);
    });

    testWidgets('export routes the generated report to the share callback',
        (tester) async {
      final state = await testingState(_StubDiagnostics());
      String? sharedPath;

      await tester.pumpWidget(MaterialApp(
        home: DiagnosticsScreen(
          state: state,
          onShare: (path) async {
            sharedPath = path;
          },
        ),
      ));

      await tester.tap(find.byIcon(Icons.ios_share));
      await tester.pumpAndSettle();

      expect(sharedPath, '<stub-report>');
    });
  });
}

/// A stub exportReport so widget tests route the report without any file IO:
/// dart:io futures never complete inside the fake-async zone of testWidgets.
class _StubDiagnostics extends Diagnostics {
  @override
  Future<String> exportReport() async => '<stub-report>';
}

Future<List<String>> linesOf(File file) async {
  final text = await file.readAsString();
  return text.split('\n').where((line) => line.trim().isNotEmpty).toList();
}
