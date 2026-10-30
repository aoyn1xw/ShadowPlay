import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shadowplay/core/app_state.dart';
import 'package:shadowplay/core/models.dart';
import 'package:shadowplay/core/shadowplay_api.dart';

/// Race-condition and pairing-trust tests for [AppState], using two real
/// HTTP servers that stand in for paired PCs so tokens, responses, and
/// timings behave exactly like the production transport.
void main() {
  late _ScriptedServer serverA;
  late _ScriptedServer serverB;
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    serverA = _ScriptedServer('a', 'tokA');
    serverB = _ScriptedServer('b', 'tokB');
    await serverA.start();
    await serverB.start();
  });

  tearDown(() async {
    await serverA.close();
    await serverB.close();
  });

  Connection device(_ScriptedServer server) => Connection(
        serverId: server.serverId,
        computerName: server.serverId.toUpperCase(),
        address: '127.0.0.1',
        port: server.port,
      );

  AppState buildState({
    String? activeServerId,
    Map<String, String> tokens = const {'a': 'tokA', 'b': 'tokB'},
    _FakeSecureStorage? secureStorage,
  }) =>
      AppState.forTesting(
        preferences,
        connections: [device(serverA), device(serverB)],
        activeServerId: activeServerId,
        activeToken: activeServerId == null ? null : tokens[activeServerId],
        tokens: tokens,
        secureStorage: secureStorage,
      );

  group('device switching and response races', () {
    test(
        'a late response from a previously selected PC cannot overwrite the '
        'active PC state', () async {
      final state = buildState(activeServerId: 'a');

      // Freeze PC A's /server response after its token has been verified.
      serverA.gate();
      final lateRefresh = state.refreshClips();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(state.clipsLoading, isTrue);

      // Switch to PC B while A's response is still parked at the server.
      await state.select(device(serverB));
      expect(state.activeServerId, 'b');
      expect(state.clipsLoading, isFalse);
      expect(state.remoteClips.single.id, 'b' * 64);

      // Release A's late response.
      serverA.release();
      await lateRefresh;

      // The active device's data must be untouched by the stale response.
      expect(state.activeServerId, 'b');
      expect(state.remoteClips.single.id, 'b' * 64);
      expect(state.serverInfos.containsKey('a'), isFalse,
          reason: 'the superseded refresh must not publish server info');
      expect(state.clipLoadError, isNull);
      expect(state.deviceStatuses.containsKey('a'), isFalse,
          reason: 'the stale refresh must not publish any device status');
      expect(
          state.deviceStatuses['b']?.availability, DeviceAvailability.online);
    });

    test('a late failure from a previously selected PC is discarded', () async {
      final state = buildState(activeServerId: 'a');
      serverA.gate();
      serverA.failAfterRelease = true;
      final lateRefresh = state.refreshClips();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      await state.select(device(serverB));
      serverA.release();
      await lateRefresh;

      expect(state.activeServerId, 'b');
      expect(state.clipLoadError, isNull,
          reason: 'stale failures must not be shown for the new device');
      expect(
          state.deviceStatuses['b']?.availability, DeviceAvailability.online);
    });

    test('overlapping refreshes converge on the newest data', () async {
      final state = buildState(activeServerId: 'a');
      await Future.wait([
        state.refreshClips(),
        state.refreshClips(),
      ]);

      expect(state.remoteClips.single.id, 'a' * 64);
      expect(state.clipsLoading, isFalse);
      expect(state.clipLoadError, isNull);
      expect(state.serverInfos['a']?.serverId, 'a');
      expect(
          state.deviceStatuses['a']?.availability, DeviceAvailability.online);
    });

    test('downloading progress state is keyed per device, not per clip id',
        () async {
      // Two PCs can expose the same clip identifier; the keys must never
      // collide. This exercises the published helper contract directly.
      final state = buildState(activeServerId: 'a');
      final sharedClipId = 'de' * 32;

      state.downloadProgress[AppState.deviceKey('a', sharedClipId)] = 0.5;
      state.downloadFailures[AppState.deviceKey('b', sharedClipId)] = 'oops';

      expect(state.isDownloadingClip(sharedClipId), isTrue,
          reason: 'active PC a is downloading');
      expect(state.getProgress(device(serverA), sharedClipId), 0.5);
      expect(state.getFailure(null, sharedClipId), isNull,
          reason: 'the b failure must not surface while a is active');
    });
  });

  group('pairing trust', () {
    test('QR pin conflicting with the server certificate fails loudly',
        () async {
      final state = buildState();
      final response = {
        'token': 'tokX',
        'server': {
          'serverId': 'x',
          'computerName': 'XavierPC',
          'clipCount': 0,
          'apiVersion': 1,
          'httpsPort': 5178,
          'httpsCertSha256':
              'bebebebebebebebebebebebebebebebebebebebebebebebebebebebebebebebe',
        },
      };

      await expectLater(
        state.addPaired(
          response,
          '10.0.0.5',
          5177,
          httpsPort: 5178,
          certSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        throwsA(predicate((error) =>
            error is ApiException &&
            error.kind == ApiFailureKind.tlsUntrusted &&
            error.message.contains('different certificate'))),
      );
      expect(state.connections.any((connection) => connection.serverId == 'x'),
          isFalse,
          reason: 'a certificate conflict must not create a connection');
    });

    test('manual legacy pairing without pins keeps plain HTTP', () async {
      final storage = _FakeSecureStorage();
      final state = buildState(secureStorage: storage);
      final response = {
        'token': 'tokLegacy',
        'server': {
          'serverId': 'legacy',
          'computerName': 'LegacyPC',
          'clipCount': 0,
          'apiVersion': 1,
        },
      };

      await state.addPaired(response, '10.0.0.9', 5177);

      final legacy = state.connections
          .singleWhere((connection) => connection.serverId == 'legacy');
      expect(legacy.usesTls, isFalse);
      expect(state.activeServerId, 'legacy');
      expect(storage.store['token_legacy'], 'tokLegacy');
      expect(state.deviceStatuses['legacy']?.availability,
          DeviceAvailability.online);
    });
  });

  group('pairing protocol parsing', () {
    test('v2 payloads expose pinned TLS parameters', () {
      final payload = PairingPayload.fromJson({
        'v': 2,
        'serverId': 'srv',
        'computerName': 'Windows PC',
        'lanAddress': '192.168.1.10',
        'port': 5177,
        'pairingCode': 'ABCD-1234',
        'httpsPort': 5178,
        'certSha256': 'AB' * 32,
      });

      expect(payload.tlsPinned, isTrue);
      expect(payload.usesLegacyHttp, isFalse);
      expect(payload.address, '192.168.1.10');
      expect(payload.httpsPort, 5178);
      expect(normalizeFingerprint(payload.certSha256), 'ab' * 32);
    });

    test('v1 payloads remain legal and stay legacy HTTP', () {
      final payload = PairingPayload.fromJson({
        'v': 1,
        'serverId': 'srv',
        'computerName': 'Windows PC',
        'lanAddress': '192.168.1.10',
        'port': 5177,
        'pairingCode': 'ABCD-1234',
      });

      expect(payload.tlsPinned, isFalse);
      expect(payload.usesLegacyHttp, isTrue);
    });

    test('unknown protocol versions are rejected with a friendly error', () {
      expect(
        () => PairingPayload.fromJson({
          'v': 3,
          'serverId': 'srv',
          'computerName': 'Windows PC',
          'lanAddress': '192.168.1.10',
          'port': 5177,
          'pairingCode': 'ABCD-1234',
        }),
        throwsFormatException,
      );
    });

    test('normalizer rejects malformed fingerprints', () {
      expect(normalizeFingerprint(null), isNull);
      expect(normalizeFingerprint(''), isNull);
      expect(normalizeFingerprint('zzzzzz'), isNull,
          reason: 'non-hex input is rejected');
      expect(normalizeFingerprint('ab' * 31), isNull,
          reason: 'short hashes are not fingerprints');
      expect(normalizeFingerprint('ab' * 33), isNull,
          reason: 'long hashes are not fingerprints');
      expect(normalizeFingerprint('AB' * 32), 'ab' * 32,
          reason: 'uppercase hex is canonicalised');
      expect(normalizeFingerprint('AB:' * 31 + 'AB'), 'ab' * 32,
          reason: 'colon groups are stripped');
    });
  });
}

/// HTTP server standing in for a paired PC. Serves only the endpoints the
/// under-test app state consumes. Asserts the bearer token for its own
/// device so cross-device token leakage turns into a hard test failure.
class _ScriptedServer {
  _ScriptedServer(this.serverId, this.token);

  final String serverId;
  final String token;

  late final HttpServer _http;
  Completer<void>? _gate;

  /// When true, /server responds with 500 after [release].
  bool failAfterRelease = false;

  int get port => _http.port;

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen(_handle);
  }

  Future<void> close() async {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    _gate = null;
    await _http.close(force: true);
  }

  /// Queues incoming /server requests behind a gate until [release] runs.
  void gate() => _gate = Completer<void>();

  void release() => _gate?.complete();

  Future<void> _handle(HttpRequest request) async {
    final supplied = request.headers.value(HttpHeaders.authorizationHeader);
    if (supplied != 'Bearer $token') {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }

    final pending = _gate;
    if (pending != null) {
      await pending.future;
    }

    if (failAfterRelease && request.uri.path == '/api/v1/server') {
      request.response.statusCode = 500;
      await request.response.close();
      return;
    }

    switch (request.uri.path) {
      case '/api/v1/server':
        await _json(request, {
          'serverId': serverId,
          'computerName': serverId.toUpperCase(),
          'clipCount': 1,
          'serverVersion': '0.1.0',
          'apiVersion': 1,
          'capabilities': <String>[],
          'protocolVersion': 2,
        });
        break;
      case '/api/v1/clips':
        await _json(request, [
          {
            'id': serverId == 'a' ? 'a' * 64 : 'b' * 64,
            'fileName': serverId == 'a' ? 'alpha.mp4' : 'bravo.mp4',
            'sizeBytes': serverId == 'a' ? 123 : 456,
            'lastWriteTimeUtc': serverId == 'a'
                ? '2026-01-01T00:00:00.000Z'
                : '2026-01-02T00:00:00.000Z',
          },
        ]);
        break;
      default:
        request.response.statusCode = 404;
        await request.response.close();
    }
  }

  Future<void> _json(HttpRequest request, Object payload) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

/// In-memory stand-in for the OS secure storage so pairing tests can read
/// back persisted tokens without a platform plugin.
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> store = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}
