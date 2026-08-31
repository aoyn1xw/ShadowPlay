import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/media_gallery.dart';
import 'package:shadowplay/core/models.dart';
import 'package:shadowplay/core/shadowplay_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('pairing payload accepts the protocol v1 desktop QR shape', () {
    final payload = PairingPayload.fromJson({
      'v': 1,
      'serverId': 'server-1',
      'computerName': 'GAMING-PC',
      'lanAddress': '192.168.1.20',
      'port': 5177,
      'pairingCode': 'ABCD-1234',
    });

    expect(payload.computerName, 'GAMING-PC');
    expect(payload.address, '192.168.1.20');
    expect(payload.port, 5177);
  });

  test('connection persistence remains compatible without lastSeenUtc', () {
    final connection = Connection.fromJson({
      'serverId': 'server-1',
      'computerName': 'PC 1',
      'address': '192.168.1.20',
      'port': 5177,
    });

    expect(connection.lastSeenUtc, isNull);
    expect(connection.toJson()['serverId'], 'server-1');
  });

  test('clip and server metadata remain backward compatible', () {
    final clip = Clip.fromJson({
      'id': List.filled(64, 'a').join(),
      'fileName': 'Ace.mp4',
      'sizeBytes': 1000,
      'lastWriteTimeUtc': '2026-08-28T14:30:00Z',
      'durationMilliseconds': 12500,
      'thumbnailUrl': '/api/v1/clips/thumbnail',
    });
    final oldServer = ServerInfo.fromJson({
      'serverId': 'server-1',
      'computerName': 'PC 1',
      'clipCount': 1,
      'protocolVersion': 1,
    });

    expect(clip.duration, const Duration(milliseconds: 12500));
    expect(clip.thumbnailUrl, '/api/v1/clips/thumbnail');
    expect(oldServer.serverVersion, isNull);
    expect(oldServer.apiVersion, 1);
    expect(oldServer.capabilities, isEmpty);
    expect(oldServer.supports('clips.thumbnails'), isFalse);
  });

  test('newer server API versions are rejected clearly', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode({
            'status': 'ok',
            'serverId': 'server-1',
            'computerName': 'PC 1',
            'clipCount': 0,
            'apiVersion': 2,
          }),
          200,
        ));

    final api = ShadowPlayApi(
      Connection(
        serverId: 'server-1',
        computerName: 'PC 1',
        address: '192.168.1.20',
        port: 5177,
      ),
      'token',
    );

    // Compatibility is checked during the pairing health preflight.
    await expectLater(
      ShadowPlayApi.pair(
        address: '192.168.1.20',
        port: 5177,
        code: 'ABCD-1234',
        deviceName: 'iPhone',
        client: client,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.kind,
          'kind',
          ApiFailureKind.apiIncompatible,
        ),
      ),
    );
    final id = List.filled(64, 'a').join();
    expect(
        api
            .clipStreamUri(Clip(
              id: id,
              fileName: 'Ace.mp4',
              sizeBytes: 100,
              lastWriteTimeUtc: DateTime.utc(2026, 8, 28),
            ))
            .path,
        '/api/v1/clips/$id/download');
  });

  test('thumbnail requests reuse the authenticated API contract', () async {
    final id = List.filled(64, 'b').join();
    final client = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer token');
      expect(request.url.path, '/api/v1/clips/$id/thumbnail');
      return http.Response.bytes([137, 80, 78, 71], 200);
    });
    final api = ShadowPlayApi(
      Connection(
        serverId: 'server-1',
        computerName: 'PC 1',
        address: '192.168.1.20',
        port: 5177,
      ),
      'token',
    );

    expect(
      await api.thumbnail(
        Clip(
          id: id,
          fileName: 'Ace.mp4',
          sizeBytes: 100,
          lastWriteTimeUtc: DateTime.utc(2026, 8, 28),
          thumbnailUrl: '/api/v1/clips/$id/thumbnail',
        ),
        client: client,
      ),
      [137, 80, 78, 71],
    );
  });

  test('onboarding stays complete only while at least one PC remains paired',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final connection = Connection(
      serverId: 'server-1',
      computerName: 'PC 1',
      address: '192.168.1.20',
      port: 5177,
    );
    final paired = AppState.forTesting(
      preferences,
      connections: [connection],
      activeServerId: connection.serverId,
    );

    expect(paired.needsOnboarding, isTrue);
    await paired.completeOnboarding();
    expect(paired.needsOnboarding, isFalse);

    final unpaired = AppState.forTesting(
      preferences,
      onboardingCompleted: true,
    );
    expect(unpaired.needsOnboarding, isTrue);
  });

  test('a downloaded clip leaves the new-clips queue', () async {
    final preferences = await SharedPreferences.getInstance();
    final clip = Clip(
      id: List.filled(64, 'a').join(),
      fileName: 'Ace.mp4',
      sizeBytes: 1000,
      lastWriteTimeUtc: DateTime.utc(2026, 8, 28),
    );
    final state = AppState.forTesting(
      preferences,
      remoteClips: [clip],
      downloadedClips: [
        DownloadedClip(
          id: clip.id,
          fileName: clip.fileName,
          sizeBytes: clip.sizeBytes,
          lastWriteTimeUtc: clip.lastWriteTimeUtc,
          localPath: 'unused-in-this-test.mp4',
        ),
      ],
    );

    expect(state.newClips, isEmpty);
    expect(state.newClipCount, 0);
  });

  test('pairing performs a health preflight before consuming the code',
      () async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      if (request.url.path.endsWith('/health')) {
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      return http.Response(
        jsonEncode({
          'token': 'token',
          'deviceId': 'device',
          'server': {
            'serverId': 'server',
            'computerName': 'PC',
            'protocolVersion': 1,
            'clipCount': 0,
          },
        }),
        200,
      );
    });

    await ShadowPlayApi.pair(
      address: '192.168.0.201',
      port: 5047,
      code: 'ABCD-1234',
      deviceName: 'iPhone',
      client: client,
    );

    expect(paths, [
      '/api/v1/health',
      '/api/v1/pair/exchange',
    ]);
  });

  test('pairing reports a refused connection distinctly', () async {
    final client = MockClient((_) async {
      throw SocketException(
        'Connection refused',
        osError: OSError('Connection refused', 111),
      );
    });

    await expectLater(
      ShadowPlayApi.pair(
        address: '192.168.0.201',
        port: 5047,
        code: 'ABCD-1234',
        deviceName: 'iPhone',
        client: client,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.kind,
          'kind',
          ApiFailureKind.connectionRefused,
        ),
      ),
    );
  });

  test('pairing reports a private-network HTTP rejection distinctly', () async {
    final client = MockClient((_) async {
      return http.Response(jsonEncode({'error': 'forbidden'}), 403);
    });

    await expectLater(
      ShadowPlayApi.pair(
        address: '192.168.0.201',
        port: 5047,
        code: 'ABCD-1234',
        deviceName: 'iPhone',
        client: client,
      ),
      throwsA(
        isA<ApiException>()
            .having(
                (error) => error.kind, 'kind', ApiFailureKind.networkIsolation)
            .having((error) => error.statusCode, 'status', 403),
      ),
    );
  });

  test('pairing reports malformed health JSON distinctly', () async {
    final client = MockClient((_) async => http.Response('{bad json', 200));

    await expectLater(
      ShadowPlayApi.pair(
        address: '192.168.0.201',
        port: 5047,
        code: 'ABCD-1234',
        deviceName: 'iPhone',
        client: client,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.kind,
          'kind',
          ApiFailureKind.malformedResponse,
        ),
      ),
    );
  });

  test('pairing reports timeout distinctly', () async {
    final client = MockClient((_) async {
      throw TimeoutException('test timeout');
    });

    await expectLater(
      ShadowPlayApi.pair(
        address: '192.168.0.201',
        port: 5047,
        code: 'ABCD-1234',
        deviceName: 'iPhone',
        client: client,
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.kind,
          'kind',
          ApiFailureKind.timeout,
        ),
      ),
    );
  });

  test('downloaded clips can be exported to the media gallery', () async {
    final preferences = await SharedPreferences.getInstance();
    final gallery = _FakeMediaGallery();
    final clip = DownloadedClip(
      id: 'clip-1',
      fileName: 'Ace.mp4',
      sizeBytes: 100,
      lastWriteTimeUtc: DateTime.utc(2026, 8, 28),
      localPath: 'clip-1.mp4',
    );
    final state = AppState.forTesting(
      preferences,
      mediaGallery: gallery,
      downloadedClips: [clip],
    );

    expect(await state.saveClipToGallery(clip), isTrue);
    expect(gallery.savedPaths, ['clip-1.mp4']);
    expect(state.gallerySavedIds, contains('clip-1'));
    expect(state.gallerySaveFailures, isEmpty);
  });

  test('gallery export failure preserves the local clip and reports why',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final gallery = _FakeMediaGallery()
      ..error = const GalleryAccessDeniedException();
    final clip = DownloadedClip(
      id: 'clip-2',
      fileName: 'Denied.mp4',
      sizeBytes: 100,
      lastWriteTimeUtc: DateTime.utc(2026, 8, 28),
      localPath: 'clip-2.mp4',
    );
    final state = AppState.forTesting(
      preferences,
      mediaGallery: gallery,
      downloadedClips: [clip],
    );

    expect(await state.saveClipToGallery(clip), isFalse);
    expect(state.downloadedClips, contains(clip));
    expect(state.gallerySaveFailures['clip-2'], contains('not granted'));
  });
}

class _FakeMediaGallery implements MediaGallery {
  final savedPaths = <String>[];
  Object? error;

  @override
  Future<void> saveVideo(String path) async {
    if (error != null) throw error!;
    savedPaths.add(path);
  }
}
