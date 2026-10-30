import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;

import 'models.dart';
import 'resumable_download.dart';

enum ApiFailureKind {
  timeout,
  connectionRefused,
  networkUnreachable,
  networkIsolation,
  authenticationFailure,
  apiIncompatible,
  tlsUntrusted,
  network,
  http,
  malformedResponse,
  protocol,
  unknown,
}

class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.kind = ApiFailureKind.unknown,
    this.statusCode,
  });
  final String message;
  final ApiFailureKind kind;
  final int? statusCode;

  @override
  String toString() => message;
}

class ShadowPlayApi {
  const ShadowPlayApi(this.connection, this.token);

  static const _requestTimeout = Duration(seconds: 20);
  static const _pairingTimeout = Duration(seconds: 30);

  final Connection connection;
  final String token;

  // ------------------------------------------------------------------ URIs

  Uri _uri(String path) {
    final scheme = connection.usesTls ? 'https' : 'http';
    final port = connection.usesTls
        ? connection.httpsPort ?? connection.port
        : connection.port;
    return Uri(
      scheme: scheme,
      host: connection.address,
      port: port,
      path: '/api/v1$path',
    );
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Map<String, String> get authorizationHeaders => Map.unmodifiable(_headers);

  Uri clipStreamUri(Clip clip) => _uri('/clips/${clip.id}/download');

  // ----------------------------------------------------------- transports

  /// A `dart:io` HttpClient honouring the pinned-certificate policy of a
  /// connection. When a pin is configured, a certificate whose SHA-256
  /// fingerprint does not match is always rejected — connections never
  /// silently downgrade.
  static HttpClient ioClient({
    required bool useTls,
    String? pinnedCertSha256,
    Duration? connectionTimeout,
  }) {
    final inner = HttpClient();
    inner.connectionTimeout = connectionTimeout ?? _requestTimeout;
    if (useTls) {
      final pinned = normalizeFingerprint(pinnedCertSha256);
      if (pinned == null) {
        // Defensive: a pinned connection must never be created without its
        // pin. Callers surface this as a protocol failure, not a downgrade.
        throw const ApiException(
          'Secure connection requested without a pinned certificate.',
          kind: ApiFailureKind.protocol,
        );
      }
      inner.badCertificateCallback =
          (cert, host, port) => certificateMatchesPin(cert, pinned);
    }
    return inner;
  }

  static http.Client transportClient(Connection connection,
      {Duration? connectionTimeout}) {
    final inner = ioClient(
      useTls: connection.usesTls,
      pinnedCertSha256: connection.certSha256,
      connectionTimeout: connectionTimeout,
    );
    return http_io.IOClient(inner);
  }

  /// SHA-256 pin check for a presented certificate.
  static bool certificateMatchesPin(
      X509Certificate cert, String pinnedNormalized) {
    try {
      final digest = sha256.convert(cert.der).toString();
      return _constantTimeHexEquals(digest, pinnedNormalized.toLowerCase());
    } catch (_) {
      return false;
    }
  }

  static bool _constantTimeHexEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ------------------------------------------------------------- requests

  Future<List<Clip>> clips({http.Client? client}) async {
    final uri = _uri('/clips');
    return _run(
        client: client,
        uri: uri,
        body: (owned) async {
          final response =
              await _withTimeout(owned.get(uri, headers: _headers), uri);
          _check(response.statusCode, uri);
          try {
            final body = jsonDecode(response.body);
            if (body is! List<dynamic>) {
              throw const FormatException('Expected a clip list.');
            }
            return body
                .map((item) => Clip.fromJson(item as Map<String, dynamic>))
                .toList();
          } on ApiException {
            rethrow;
          } catch (error) {
            throw ApiException(
              'The PC returned an invalid clip list. Restart ShadowPlay and try again.',
              kind: ApiFailureKind.malformedResponse,
            );
          }
        });
  }

  Future<ServerInfo> serverInfo({http.Client? client}) async {
    final uri = _uri('/server');
    return _run(
        client: client,
        uri: uri,
        body: (owned) async {
          final response =
              await _withTimeout(owned.get(uri, headers: _headers), uri);
          _check(response.statusCode, uri);
          try {
            final body = jsonDecode(response.body);
            if (body is! Map<String, dynamic>) {
              throw const FormatException('Expected a server object.');
            }
            _checkApiCompatibility(body);
            return ServerInfo.fromJson(body);
          } catch (error) {
            if (error is ApiException) rethrow;
            throw const ApiException(
              'The PC returned an invalid server response. Restart ShadowPlay and try again.',
              kind: ApiFailureKind.malformedResponse,
            );
          }
        });
  }

  Future<List<int>> thumbnail(Clip clip, {http.Client? client}) async {
    final uri = _uri('/clips/${clip.id}/thumbnail');
    return _run(
        client: client,
        uri: uri,
        body: (owned) async {
          final response =
              await _withTimeout(owned.get(uri, headers: _headers), uri);
          _check(response.statusCode, uri);
          return response.bodyBytes;
        });
  }

  /// Opens a resumable download segment. The returned [DownloadSegment] owns
  /// its transport and must be disposed after the body is consumed.
  Future<DownloadSegment> openDownload(Clip clip, {int? rangeStart}) async {
    final uri = clipStreamUri(clip);
    final inner = http_io.IOClient(
      ioClient(
        useTls: connection.usesTls,
        pinnedCertSha256: connection.certSha256,
      ),
    );
    try {
      final request = http.Request('GET', uri);
      request.headers.addAll(_headers);
      if (rangeStart != null && rangeStart > 0) {
        request.headers['Range'] = 'bytes=$rangeStart-';
      }
      final response = await _withTimeout(request.send(), uri);
      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 404) {
        _check(response.statusCode, uri);
      }
      return _segmentFrom(response, () async {
        inner.close();
      });
    } on ApiException {
      inner.close();
      rethrow;
    } catch (error) {
      inner.close();
      rethrow;
    }
  }

  static DownloadSegment _segmentFrom(
      http.StreamedResponse response, Future<void> Function() dispose) {
    final headers = response.headers;
    final contentLength =
        response.contentLength != null && response.contentLength! >= 0
            ? response.contentLength
            : _parseNullableInt(headers['content-length']);

    int? rangeStart;
    int? rangeTotal;
    final contentRange = headers['content-range'];
    if (contentRange != null) {
      final full =
          RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$').firstMatch(contentRange);
      if (full != null) {
        rangeStart = int.parse(full.group(1)!);
        rangeTotal = int.parse(full.group(3)!);
      } else {
        // 416 responses use `bytes */total` (no satisfiable range).
        final starOnly = RegExp(r'^bytes\s+\*/(\d+)$').firstMatch(contentRange);
        if (starOnly != null) {
          rangeTotal = int.parse(starOnly.group(1)!);
        }
      }
    }

    return DownloadSegment(
      statusCode: response.statusCode,
      body: response.stream,
      dispose: dispose,
      contentLength: contentLength,
      contentRangeStart: rangeStart,
      contentRangeTotal: rangeTotal,
    );
  }

  static int? _parseNullableInt(String? value) =>
      value == null ? null : int.tryParse(value.trim());

  // -------------------------------------------------------------- pairing

  static Future<Map<String, dynamic>> health({
    required String address,
    required int port,
    http.Client? client,
    bool useTls = false,
    String? pinnedCertSha256,
  }) async {
    final uri = _endpointUri(address, port, '/health', useTls: useTls);
    final ownedClient = _ownedStaticClient(client, useTls, pinnedCertSha256);
    try {
      final response =
          await _withTimeout(ownedClient.get(uri), uri, pairing: true);
      _check(response.statusCode, uri);
      try {
        final body = jsonDecode(response.body);
        if (body is! Map<String, dynamic> || body['status'] != 'ok') {
          throw const FormatException('Unexpected health response.');
        }
        _checkApiCompatibility(body);
        return body;
      } catch (error) {
        if (error is ApiException) rethrow;
        throw ApiException(
          'The PC returned an invalid health response. Restart ShadowPlay and try again.',
          kind: ApiFailureKind.malformedResponse,
        );
      }
    } finally {
      if (client == null) ownedClient.close();
    }
  }

  static Future<Map<String, dynamic>> pair({
    required String address,
    required int port,
    required String code,
    required String deviceName,
    http.Client? client,
    bool useTls = false,
    String? pinnedCertSha256,
  }) async {
    final uri = _endpointUri(address, port, '/pair/exchange', useTls: useTls);
    final ownedClient = _ownedStaticClient(client, useTls, pinnedCertSha256);
    try {
      // Do not consume the one-time code until the phone has proved that the
      // decoded address is reachable and is speaking the expected API.
      await health(
        address: address,
        port: port,
        client: ownedClient,
        useTls: useTls,
        pinnedCertSha256: pinnedCertSha256,
      );

      final response = await _withTimeout(
        ownedClient.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'pairingCode': code, 'deviceName': deviceName}),
        ),
        uri,
        pairing: true,
      );
      _check(response.statusCode, uri);
      try {
        final body = jsonDecode(response.body);
        if (body is! Map<String, dynamic>) {
          throw const FormatException('Expected a pairing response.');
        }
        return body;
      } catch (error) {
        if (error is ApiException) rethrow;
        throw const ApiException(
          'The PC returned an invalid pairing response. Restart ShadowPlay and try again.',
          kind: ApiFailureKind.malformedResponse,
        );
      }
    } finally {
      if (client == null) ownedClient.close();
    }
  }

  static http.Client _ownedStaticClient(
      http.Client? provided, bool useTls, String? pinnedCertSha256) {
    if (provided != null) return provided;
    if (useTls) {
      return http_io.IOClient(
        ioClient(
          useTls: true,
          pinnedCertSha256: pinnedCertSha256,
          connectionTimeout: _pairingTimeout,
        ),
      );
    }
    return http.Client();
  }

  static Uri _endpointUri(String address, int port, String path,
      {required bool useTls}) {
    return Uri(
      scheme: useTls ? 'https' : 'http',
      host: address,
      port: port,
      path: '/api/v1$path',
    );
  }

  // ------------------------------------------------------------- plumbing

  /// Runs [body] with an owned (or provided) transport, closing the owned
  /// transport after the request completes.
  static Future<T> _run<T>({
    required http.Client? client,
    required Uri uri,
    required Future<T> Function(http.Client owned) body,
  }) async {
    if (client != null) return body(client);
    final owned = http.Client();
    try {
      return await body(owned);
    } finally {
      owned.close();
    }
  }

  static void _check(int statusCode, Uri uri) {
    if (statusCode == 409) {
      throw const ApiException(
        'Pairing code invalid, expired, or already used. Generate a new code on the PC.',
        kind: ApiFailureKind.http,
        statusCode: 409,
      );
    }
    if (statusCode == 401) {
      throw const ApiException(
        'Authentication failed. This phone may have been revoked; pair with the PC again.',
        kind: ApiFailureKind.authenticationFailure,
        statusCode: 401,
      );
    }
    if (statusCode == 403) {
      throw const ApiException(
        'Windows blocked this LAN request. Mark the Wi-Fi network Private and connect both devices to the same network.',
        kind: ApiFailureKind.networkIsolation,
        statusCode: 403,
      );
    }
    if (statusCode == 404) {
      throw const ApiException(
        'That clip is no longer available on the PC.',
        kind: ApiFailureKind.http,
        statusCode: 404,
      );
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw ApiException(
        'The PC returned HTTP $statusCode for ${uri.path}.',
        kind: ApiFailureKind.http,
        statusCode: statusCode,
      );
    }
  }

  static Future<T> _withTimeout<T>(
    Future<T> request,
    Uri uri, {
    bool pairing = false,
  }) async {
    final timeout = pairing ? _pairingTimeout : _requestTimeout;
    try {
      return await request.timeout(timeout);
    } on TimeoutException {
      throw ApiException(
        'ShadowPlay did not respond at ${uri.host}:${uri.port}. Check that the PC is awake, sharing is running, and both devices are on the same Wi-Fi.',
        kind: ApiFailureKind.timeout,
      );
    } on SocketException catch (error) {
      throw _transportError(error, uri);
    } on HandshakeException catch (error) {
      throw _tlsError(error, uri);
    } on http.ClientException catch (error) {
      // http's ClientException carries no cause object; the message usually
      // names the underlying peer reset. Keep the generic network mapping —
      // handshake failures surface directly as HandshakeException through
      // dart:io transports, so TLS trust errors are not lost here.
      throw _transportError(error, uri);
    }
  }

  static ApiException _tlsError(HandshakeException error, Uri uri) {
    return ApiException(
      'ShadowPlay could not verify the PC identity over the encrypted link '
      '(${uri.host}:${uri.port}). The PC certificate may have changed; '
      're-pair the phone from the QR code on the PC.',
      kind: ApiFailureKind.tlsUntrusted,
    );
  }

  static ApiException _transportError(Object error, Uri uri) {
    final message = error.toString();
    final lower = message.toLowerCase();
    final code = error is SocketException ? error.osError?.errorCode : null;

    if (code == 111 ||
        code == 61 ||
        code == 10061 ||
        lower.contains('connection refused')) {
      return ApiException(
        'The ShadowPlay server is unavailable at ${uri.host}:${uri.port}. Start sharing on the PC and check Windows Firewall.',
        kind: ApiFailureKind.connectionRefused,
      );
    }
    if (code == 101 ||
        code == 51 ||
        code == 10051 ||
        code == 113 ||
        code == 65 ||
        code == 10065 ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host')) {
      return ApiException(
        'The phone cannot route to ${uri.host}:${uri.port}. Check Wi-Fi, VPN settings, and that both devices are on the same LAN.',
        kind: ApiFailureKind.networkUnreachable,
      );
    }
    return ApiException(
      'A network error prevented reaching ${uri.host}:${uri.port}. Check Wi-Fi, VPN settings, and Windows Firewall. ($message)',
      kind: ApiFailureKind.network,
    );
  }

  static void _checkApiCompatibility(Map<String, dynamic> body) {
    final apiVersion = (body['apiVersion'] as num?)?.toInt();
    if (apiVersion != null && apiVersion > 1) {
      throw ApiException(
        'This PC requires a newer ShadowPlay mobile app (API v$apiVersion). Update the phone app and try again.',
        kind: ApiFailureKind.apiIncompatible,
      );
    }
  }
}
