import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadowplay/core/models.dart';
import 'package:shadowplay/core/resumable_download.dart';
import 'package:shadowplay/core/shadowplay_api.dart';

/// End-to-end tests for the verified resumable downloader, exercised through
/// the real `ShadowPlayApi.openDownload` transport against a scripted local
/// HTTP server. Each test controls raw responses so every HTTP edge case the
/// LAN downloader can encounter is reproducible without a Windows PC.
void main() {
  const expectedSize = 60;
  final fullBody = List<int>.generate(expectedSize, (i) => i + 1);

  late HttpServer server;
  late Directory tempDir;
  late File partFile;
  late Connection connection;
  late ShadowPlayApi api;
  late Clip clip;

  /// Installs a request handler: index counts requests across both transfer
  /// attempts inside a single test. Handler errors (e.g. writes to a socket
  /// the client already abandoned) are contained so they cannot fail tests.
  Future<void> serve(
    Future<void> Function(HttpRequest request, int index) handler,
  ) async {
    var counter = 0;
    server.listen((request) async {
      final index = counter++;
      try {
        await handler(request, index);
      } catch (_) {
        // Scripted handlers may write into sockets the client already gave
        // up on; that must not escalate into a failure of the test itself.
      }
      try {
        await request.response.close();
      } catch (_) {
        // Same as above.
      }
    });
  }

  Future<DownloadResult> runDownloader({
    File? part,
    int? expected,
    Duration? stall,
    int maxResets = 2,
    CancelToken? token,
    void Function(double)? onProgress,
  }) =>
      ResumableDownloader(
        openSegment: (rangeStart) =>
            api.openDownload(clip, rangeStart: rangeStart),
        partFile: part ?? partFile,
        expectedSize: expected ?? clip.sizeBytes,
        cancelToken: token,
        onProgress: onProgress,
        stallTimeout: stall ?? const Duration(seconds: 30),
        maxServerResets: maxResets,
      ).download();

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    tempDir = await Directory.systemTemp.createTemp('shadowplay-dl');
    partFile =
        File('${tempDir.path}${Platform.pathSeparator}aaaaaaaa_test.mp4.part');
    connection = Connection(
      serverId: 'srv-test',
      computerName: 'TestPC',
      address: '127.0.0.1',
      port: server.port,
    );
    api = ShadowPlayApi(connection, 'test-token');
    clip = Clip(
      id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      fileName: 'test.mp4',
      sizeBytes: expectedSize,
      lastWriteTimeUtc: DateTime.utc(2020),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await tempDir.delete(recursive: true);
  });

  group('successful transfers', () {
    test('full download with exact Content-Length succeeds', () async {
      await serve((request, _) async {
        expect(request.headers.value(HttpHeaders.authorizationHeader),
            'Bearer test-token');
        request.response.contentLength = fullBody.length;
        await request.response.addStream(Stream<List<int>>.value(fullBody));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody);
    });

    test('download succeeds when Content-Length is absent (chunked)', () async {
      await serve((request, _) async {
        // Chunked transfer: no contentLength declared at all. The engine
        // must not depend on a usable Content-Length being present.
        await request.response.addStream(Stream<List<int>>.value(fullBody));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody);
    });
  });

  group('interruption and resume', () {
    test('unexpected EOF fails the transfer and preserves the partial file',
        () async {
      await serve((request, _) async {
        // Chunked framing with a short body and a clean close. This is the
        // exact wire shape a Wi-Fi drop leaves behind when the byte stream
        // simply stops early: the transport ends the body after 25 bytes
        // while the catalog says the clip is 60 bytes. The engine must fail
        // the transfer and preserve every received byte for a later resume.
        // (Deliberately NOT `Content-Length: 60 with a shortfall close`:
        // dart:io destroys that connection without flushing the pending
        // bytes, so they never reach the client on Windows.)
        await request.response
            .addStream(Stream<List<int>>.value(fullBody.sublist(0, 25)));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.failed);
      expect(partFile.existsSync(), isTrue);
      expect(partFile.lengthSync(), 25);
    });

    test('resume continues from the part file using a validated 206', () async {
      await serve((request, index) async {
        final seenRange = request.headers.value(HttpHeaders.rangeHeader);
        if (index == 0) {
          // First attempt: chunked short body ends cleanly at 25 of 60
          // bytes (the reliable way to script an early end of stream).
          await request.response
              .addStream(Stream<List<int>>.value(fullBody.sublist(0, 25)));
          return;
        }

        expect(seenRange, 'bytes=25-',
            reason: 'the retry must ask to resume from 25 bytes');
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 25-${expectedSize - 1}/$expectedSize',
        );
        final payload = fullBody.sublist(25);
        request.response.contentLength = payload.length;
        await request.response.addStream(Stream<List<int>>.value(payload));
      });

      // First attempt: interrupted (truncated) and resumable - just like the
      // app state layer, this surfaces a failure while the `.part` prefix
      // stays on disk.
      final first = await runDownloader();
      expect(first.outcome, DownloadOutcome.failed);
      expect(first.errorText, contains('after 25 of 60 bytes'));
      expect(partFile.lengthSync(), 25);

      // Automatic retrying is the app state layer's job (one download()
      // call per user-visible attempt), so the resume is a fresh call that
      // drives a Range request from the preserved part.
      final second = await runDownloader();
      expect(second.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody);
    });

    test('206 resume segment declaring a wrong total is rejected', () async {
      await serve((request, index) async {
        if (index == 0) {
          // Chunked short body (the reliable early-end mechanic): 25 of the
          // 60 catalog bytes, then a clean end of stream.
          await request.response
              .addStream(Stream<List<int>>.value(fullBody.sublist(0, 25)));
          return;
        }
        // Content-Range implies a total of 45, contradicting the catalog
        // size of 60. The engine must refuse instead of completing a
        // mismatched file.
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 25-44/45',
        );
        final payload = List<int>.generate(20, (_) => 7);
        request.response.contentLength = payload.length;
        await request.response.addStream(Stream<List<int>>.value(payload));
      });

      // Attempt 1 is an ordinary interruption; attempt 2 trips the
      // mismatching Content-Range total.
      final first = await runDownloader();
      expect(first.outcome, DownloadOutcome.failed);
      expect(first.errorText, contains('after 25 of 60 bytes'));

      final second = await runDownloader();
      expect(second.outcome, DownloadOutcome.failed);
      expect(second.errorText, contains('different size'));
      expect(partFile.lengthSync(), 25,
          reason: 'the prefix must survive a rejected resume');
    });

    test('stalled transfer fails within the stall timeout and keeps bytes',
        () async {
      // A genuinely stalled remote PC holds the socket open without sending
      // more data and without an end of body. The `dart:io` HttpServer used
      // by the scripted harnesses cannot emulate that mid-body stall (it
      // buffers everything until the handler returns), so this exercises the
      // engine directly: a prefix streams in, then the body goes silent
      // forever. The engine's stall timeout must fail the transfer while
      // keeping the received prefix resumable.
      final silentBody = StreamController<List<int>>();

      final resultFuture = ResumableDownloader(
        openSegment: (_) async => DownloadSegment(
          statusCode: 200,
          body: silentBody.stream,
          dispose: () async {
            if (!silentBody.isClosed) await silentBody.close();
          },
        ),
        partFile: partFile,
        expectedSize: expectedSize,
        stallTimeout: const Duration(milliseconds: 150),
      ).download();

      // Emit a prefix, then keep the body open with no further data.
      silentBody.add(fullBody.sublist(0, 30));

      final result = await resultFuture;
      expect(result.outcome, DownloadOutcome.failed);
      expect(result.errorText, contains('stopped sending data'));
      expect(partFile.existsSync(), isTrue);
      expect(partFile.lengthSync(), 30,
          reason: 'the stalled prefix stays on disk for a later resume');
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  group('server misbehaviour', () {
    test('server ignoring Range returns 200 and the engine restarts cleanly',
        () async {
      partFile.writeAsBytesSync(fullBody.sublist(0, 25));
      await serve((request, index) async {
        if (index == 0) {
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=25-');
        } else {
          expect(request.headers.value(HttpHeaders.rangeHeader), isNull,
              reason: 'after a 200 restart the part is discarded and the '
                  'next attempt requests the whole file');
        }
        request.response.contentLength = fullBody.length;
        await request.response.addStream(Stream<List<int>>.value(fullBody));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody,
          reason: 'no duplicate prefix bytes appended');
    });

    test('mismatched Content-Range start forces a restart', () async {
      partFile.writeAsBytesSync(fullBody.sublist(0, 25));
      await serve((request, index) async {
        if (index == 0) {
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 10-${expectedSize - 1}/$expectedSize',
          );
          final payload = fullBody.sublist(10);
          request.response.contentLength = payload.length;
          await request.response.addStream(Stream<List<int>>.value(payload));
          return;
        }
        request.response.contentLength = fullBody.length;
        await request.response.addStream(Stream<List<int>>.value(fullBody));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody);
    });

    test('declared total smaller than expected fails without appending',
        () async {
      partFile.writeAsBytesSync(fullBody.sublist(0, 20));
      await serve((request, _) async {
        final payload = fullBody.sublist(0, 10);
        request.response.contentLength = 10;
        await request.response.addStream(Stream<List<int>>.value(payload));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.failed);
      expect(result.errorText, contains('different size'));
      expect(partFile.lengthSync(), 20,
          reason: 'prefix stays intact for later recovery');
    });

    test('body exceeding the expected size fails and deletes the part',
        () async {
      final oversized = [...fullBody, 61];
      await serve((request, _) async {
        // Chunked: no declared length so the engine cannot pre-reject via
        // Content-Length; it must catch the overflow while streaming.
        await request.response.addStream(Stream<List<int>>.value(oversized));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.failed);
      expect(result.errorText, contains('more data'));
      expect(partFile.existsSync(), isFalse);
    });

    test('416 with a complete part finalises the download', () async {
      partFile.writeAsBytesSync(fullBody);
      await serve((request, _) async {
        request.response.statusCode = 416;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$expectedSize',
        );
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody);
    });

    test('416 with a partial part restarts from zero', () async {
      partFile.writeAsBytesSync(fullBody.sublist(0, 25));
      await serve((request, index) async {
        if (index == 0) {
          expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=25-');
          request.response.statusCode = 416;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$expectedSize',
          );
          return;
        }
        expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
        request.response.contentLength = fullBody.length;
        await request.response.addStream(Stream<List<int>>.value(fullBody));
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.success);
      expect(partFile.readAsBytesSync(), fullBody);
    });

    test('416 reporting a different total refuses to finalise', () async {
      partFile.writeAsBytesSync(fullBody);
      await serve((request, _) async {
        request.response.statusCode = 416;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */61',
        );
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.failed);
      expect(result.errorText, contains('different size'));
    });

    test('too many inconsistent responses exhaust the restart budget',
        () async {
      await serve((request, _) async {
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 10-59/60',
        );
        request.response.contentLength = expectedSize - 10;
        await request.response
            .addStream(Stream<List<int>>.value(fullBody.sublist(10)));
      });

      final result = await runDownloader(maxResets: 1);
      expect(result.outcome, DownloadOutcome.failed);
      expect(
        result.errorText,
        anyOf(
          contains('could not'),
          contains('inconsistent'),
        ),
      );
      expect(partFile.existsSync(), isFalse,
          reason: 'an unusable part must not linger');
    });

    test('HTTP errors surface as failures; part is preserved', () async {
      partFile.writeAsBytesSync(fullBody.sublist(0, 15));
      await serve((request, _) async {
        request.response.statusCode = 500;
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.failed);
      expect(result.errorText, contains('HTTP 500'));
      expect(partFile.lengthSync(), 15);
    });
  });

  group('authentication', () {
    test('401 fails with the configured authentication message', () async {
      await serve((request, _) async {
        request.response.statusCode = 401;
      });

      final result = await runDownloader();
      expect(result.outcome, DownloadOutcome.failed);
      expect(result.errorText, contains('revoked'));
    });
  });

  group('cancellation', () {
    test(
        'cancel token stops the transfer at the next chunk and keeps '
        'the verified prefix', () async {
      await serve((request, _) async {
        // Two HTTP chunk frames written back to back, then a clean close.
        // The outbound buffer flushes at close, so the client's decode loop
        // still yields the frames as two separate chunk events; the engine's
        // cancel check between them must abort with only the first chunk
        // appended.
        await request.response
            .addStream(Stream<List<int>>.value(fullBody.sublist(0, 20)));
        await request.response
            .addStream(Stream<List<int>>.value(fullBody.sublist(20, 60)));
      });

      final token = CancelToken();
      final result = await runDownloader(
        token: token,
        onProgress: (fraction) {
          if (fraction > 0 && !token.cancelled) {
            token.cancelled = true;
          }
        },
      );

      expect(result.outcome, DownloadOutcome.cancelled);
      expect(partFile.existsSync(), isTrue);
      expect(partFile.lengthSync(), 20,
          reason: 'the second frame must not have been appended');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('concurrency', () {
    test('parallel downloads into distinct part files all succeed', () async {
      await serve((request, _) async {
        request.response.contentLength = fullBody.length;
        await request.response.addStream(Stream<List<int>>.value(fullBody));
      });

      final results = await Future.wait([
        for (var i = 0; i < 3; i++)
          runDownloader(
              part: File(
                  '${tempDir.path}${Platform.pathSeparator}concurrent_$i.part')),
      ]);

      for (final result in results) {
        expect(result.outcome, DownloadOutcome.success);
      }
      for (var i = 0; i < 3; i++) {
        expect(
          File('${tempDir.path}${Platform.pathSeparator}concurrent_$i.part')
              .readAsBytesSync(),
          fullBody,
        );
      }
    });
  });
}
