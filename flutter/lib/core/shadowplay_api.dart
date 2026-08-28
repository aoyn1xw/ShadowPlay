import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;

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

  Future<List<Clip>> clips() async {
    final response = await _withTimeout(
      http.get(_uri('/clips'), headers: _headers),
      _requestTimeout,
    );
    _check(response.statusCode);
    return (jsonDecode(response.body) as List<dynamic>)
        .map((item) => Clip.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<ServerInfo> serverInfo() async {
    final response = await _withTimeout(
      http.get(_uri('/server'), headers: _headers),
      _requestTimeout,
    );
    _check(response.statusCode);
    return ServerInfo.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Future<http.StreamedResponse> startDownload(Clip clip) async {
    final request = http.Request('GET', _uri('/clips/${clip.id}/download'));
    request.headers.addAll(_headers);
    final response = await _withTimeout(request.send(), _requestTimeout);
    _check(response.statusCode);
    return response;
  }

  static Future<Map<String, dynamic>> pair({
    required String address,
    required int port,
    required String code,
    required String deviceName,
  }) async {
    final response = await _withTimeout(
      http.post(
        Uri(
          scheme: 'http',
          host: address,
          port: port,
          path: '/api/v1/pair/exchange',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pairingCode': code, 'deviceName': deviceName}),
      ),
      _pairingTimeout,
    );
    if (response.statusCode == 409) {
      throw const ApiException(
        'Pairing code invalid, expired, or already used. Generate a new code on the PC.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException('Pairing failed (HTTP ${response.statusCode}).');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static void _check(int statusCode) {
    if (statusCode == 401) {
      throw const ApiException('Access was revoked. Pair with this PC again.');
    }
    if (statusCode == 403) {
      throw const ApiException(
        'Connect your phone and PC to the same Wi-Fi network.',
      );
    }
    if (statusCode == 404) {
      throw const ApiException('That clip is no longer available on the PC.');
    }
    if (statusCode < 200 || statusCode >= 300) {
      throw ApiException('Request failed (HTTP $statusCode).');
    }
  }

  static Future<T> _withTimeout<T>(Future<T> request, Duration timeout) async {
    try {
      return await request.timeout(timeout);
    } on TimeoutException {
      throw const ApiException(
        'The PC did not respond. Make sure it is running and on the same Wi-Fi network.',
      );
    }
  }
}
