import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

enum ApiFailureKind {
  timeout,
  connectionRefused,
  networkUnreachable,
  networkIsolation,
  authenticationFailure,
  apiIncompatible,
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

  Uri _uri(String path) => Uri(
        scheme: 'http',
        host: connection.address,
        port: connection.port,
        path: '/api/v1$path',
      );

  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Map<String, String> get authorizationHeaders => Map.unmodifiable(_headers);

  Uri clipStreamUri(Clip clip) => _uri('/clips/${clip.id}/download');

  Future<List<Clip>> clips() async {
    final response = await _withTimeout(
      http.get(_uri('/clips'), headers: _headers),
      _requestTimeout,
      _uri('/clips'),
    );
    _check(response.statusCode, _uri('/clips'));
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
  }

  Future<ServerInfo> serverInfo() async {
    final response = await _withTimeout(
      http.get(_uri('/server'), headers: _headers),
      _requestTimeout,
      _uri('/server'),
    );
    _check(response.statusCode, _uri('/server'));
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
  }

  Future<http.StreamedResponse> startDownload(Clip clip) async {
    final request = http.Request('GET', clipStreamUri(clip));
    request.headers.addAll(_headers);
    final response = await _withTimeout(
      request.send(),
      _requestTimeout,
      request.url,
    );
    _check(response.statusCode, request.url);
    return response;
  }

  Future<List<int>> thumbnail(Clip clip, {http.Client? client}) async {
    final uri = _uri('/clips/${clip.id}/thumbnail');
    final response = await _withTimeout(
      client?.get(uri, headers: _headers) ?? http.get(uri, headers: _headers),
      _requestTimeout,
      uri,
    );
    _check(response.statusCode, uri);
    return response.bodyBytes;
  }

  static Future<Map<String, dynamic>> health({
    required String address,
    required int port,
    http.Client? client,
  }) async {
    final uri = _endpointUri(address, port, '/health');
    final ownedClient = client ?? http.Client();
    try {
      final response = await _withTimeout(
        ownedClient.get(uri),
        _pairingTimeout,
        uri,
      );
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
  }) async {
    final uri = _endpointUri(address, port, '/pair/exchange');
    final ownedClient = client ?? http.Client();
    try {
      // Do not consume the one-time code until the phone has proved that the
      // decoded address is reachable and is speaking the expected API.
      await health(address: address, port: port, client: ownedClient);

      final response = await _withTimeout(
        ownedClient.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'pairingCode': code, 'deviceName': deviceName}),
        ),
        _pairingTimeout,
        uri,
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

  static Uri _endpointUri(String address, int port, String path) => Uri(
        scheme: 'http',
        host: address,
        port: port,
        path: '/api/v1$path',
      );

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
    Duration timeout,
    Uri uri,
  ) async {
    try {
      return await request.timeout(timeout);
    } on TimeoutException {
      throw ApiException(
        'ShadowPlay did not respond at ${uri.host}:${uri.port}. Check that the PC is awake, sharing is running, and both devices are on the same Wi-Fi.',
        kind: ApiFailureKind.timeout,
      );
    } on SocketException catch (error) {
      throw _transportError(error, uri);
    } on http.ClientException catch (error) {
      throw _transportError(error, uri);
    }
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
