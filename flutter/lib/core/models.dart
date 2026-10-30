import 'dart:io';

class Clip {
  const Clip({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.lastWriteTimeUtc,
    this.duration,
    this.thumbnailUrl,
  });

  factory Clip.fromJson(Map<String, dynamic> json) => Clip(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        lastWriteTimeUtc: DateTime.parse(json['lastWriteTimeUtc'] as String),
        duration: _durationFromJson(json['durationMilliseconds']),
        thumbnailUrl: json['thumbnailUrl'] as String?,
      );

  final String id;
  final String fileName;
  final int sizeBytes;
  final DateTime lastWriteTimeUtc;
  final Duration? duration;
  final String? thumbnailUrl;
}

class ServerInfo {
  const ServerInfo({
    required this.serverId,
    required this.computerName,
    required this.clipCount,
    this.serverVersion,
    this.apiVersion = 1,
    this.capabilities = const {},
    this.httpsPort,
    this.httpsCertSha256,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        serverId: json['serverId'] as String,
        computerName: json['computerName'] as String,
        clipCount: (json['clipCount'] as num?)?.toInt() ?? 0,
        serverVersion: json['serverVersion'] as String?,
        apiVersion: (json['apiVersion'] as num?)?.toInt() ??
            (json['protocolVersion'] as num?)?.toInt() ??
            1,
        capabilities: ((json['capabilities'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toSet(),
        httpsPort: (json['httpsPort'] as num?)?.toInt(),
        httpsCertSha256: json['httpsCertSha256'] as String?,
      );

  final String serverId;
  final String computerName;
  final int clipCount;
  final String? serverVersion;
  final int apiVersion;
  final Set<String> capabilities;

  /// Port of the pinned-TLS listener advertised by this server, if any.
  final int? httpsPort;

  /// SHA-256 fingerprint (hex) of the server's leaf certificate. Trust in this
  /// value is established at pairing time via the QR code; TLS is then pinned
  /// against it. Null means the server does not offer TLS.
  final String? httpsCertSha256;

  bool supports(String capability) => capabilities.contains(capability);
}

class PairingPayload {
  const PairingPayload({
    required this.serverId,
    required this.computerName,
    required this.address,
    required this.port,
    required this.code,
    this.httpsPort,
    this.certSha256,
  });

  factory PairingPayload.fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! num || (version.toInt() != 1 && version.toInt() != 2)) {
      throw const FormatException(
          'Unsupported pairing protocol. Update the mobile app.');
    }
    return PairingPayload(
      serverId: json['serverId'] as String,
      computerName: json['computerName'] as String,
      address: json['lanAddress'] as String,
      port: (json['port'] as num).toInt(),
      code: json['pairingCode'] as String,
      httpsPort: (json['httpsPort'] as num?)?.toInt(),
      certSha256: json['certSha256'] as String?,
    );
  }

  final String serverId;
  final String computerName;
  final String address;
  final int port;
  final String code;

  /// Pinned-TLS listener port. Null/zero for v1 (legacy, plain HTTP) payloads.
  final int? httpsPort;

  /// SHA-256 fingerprint (hex) of the server certificate, pinned from the QR
  /// code itself. Trust in this value is established before any TLS handshake.
  final String? certSha256;

  bool get tlsPinned =>
      httpsPort != null && httpsPort! > 0 && _isValidFingerprint(certSha256);

  bool get usesLegacyHttp => !tlsPinned;
}

/// Validates the shape of a hex SHA-256 fingerprint.
bool _isValidFingerprint(String? value) {
  if (value == null) return false;
  final cleaned = value.replaceAll(':', '').trim().toLowerCase();
  if (cleaned.length != 64) return false;
  return cleaned.codeUnits.every((unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x61 && unit <= 0x66) ||
      (unit >= 0x41 && unit <= 0x46));
}

/// Normalizes a fingerprint to lowercase plain hex, or returns null when the
/// value is not a valid 64-character hex SHA-256 digest.
String? normalizeFingerprint(String? value) {
  if (!_isValidFingerprint(value)) return null;
  return value!.replaceAll(':', '').trim().toLowerCase();
}

class Connection {
  Connection({
    required this.serverId,
    required this.computerName,
    required this.address,
    required this.port,
    this.lastSeenUtc,
    this.httpsPort,
    this.certSha256,
  });

  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
        serverId: json['serverId'] as String,
        computerName: json['computerName'] as String,
        address: json['address'] as String,
        port: (json['port'] as num).toInt(),
        lastSeenUtc: json['lastSeenUtc'] == null
            ? null
            : DateTime.tryParse(json['lastSeenUtc'] as String),
        httpsPort: (json['httpsPort'] as num?)?.toInt(),
        certSha256: json['certSha256'] as String?,
      );

  final String serverId;
  String computerName;
  String address;
  int port;
  DateTime? lastSeenUtc;

  /// Pinned-TLS listener port. Null when this connection is legacy plain-HTTP
  /// (paired from a v1 QR/pairing exchange or never upgraded).
  int? httpsPort;

  /// SHA-256 fingerprint of the server certificate, pinned at pairing time or
  /// adopted from a trusted server-info response. Never downgrade TLS once
  /// set — a connection here speaks HTTPS only.
  String? certSha256;

  bool get usesTls =>
      httpsPort != null && httpsPort! > 0 && (certSha256?.isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'computerName': computerName,
        'address': address,
        'port': port,
        'lastSeenUtc': lastSeenUtc?.toIso8601String(),
        if (httpsPort != null) 'httpsPort': httpsPort,
        if (certSha256 != null) 'certSha256': certSha256,
      };
}

class DownloadedClip {
  const DownloadedClip({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.lastWriteTimeUtc,
    required this.localPath,
    this.duration,
    this.thumbnailUrl,
  });

  factory DownloadedClip.fromJson(Map<String, dynamic> json) => DownloadedClip(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        lastWriteTimeUtc: DateTime.parse(json['lastWriteTimeUtc'] as String),
        localPath: json['localPath'] as String,
        duration: _durationFromJson(json['durationMilliseconds']),
        thumbnailUrl: json['thumbnailUrl'] as String?,
      );

  factory DownloadedClip.fromRemote(Clip clip, File file) => DownloadedClip(
        id: clip.id,
        fileName: clip.fileName,
        sizeBytes: clip.sizeBytes,
        lastWriteTimeUtc: clip.lastWriteTimeUtc,
        localPath: file.path,
        duration: clip.duration,
        thumbnailUrl: clip.thumbnailUrl,
      );

  Clip asRemoteClip() => Clip(
        id: id,
        fileName: fileName,
        sizeBytes: sizeBytes,
        lastWriteTimeUtc: lastWriteTimeUtc,
        duration: duration,
        thumbnailUrl: thumbnailUrl,
      );

  final String id;
  final String fileName;
  final int sizeBytes;
  final DateTime lastWriteTimeUtc;
  final String localPath;
  final Duration? duration;
  final String? thumbnailUrl;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'lastWriteTimeUtc': lastWriteTimeUtc.toIso8601String(),
        'localPath': localPath,
        if (duration != null) 'durationMilliseconds': duration!.inMilliseconds,
        if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
      };
}

Duration? _durationFromJson(Object? value) {
  if (value is num && value >= 0) {
    return Duration(milliseconds: value.toInt());
  }
  return null;
}

enum DeviceAvailability { checking, online, offline }

class DeviceStatus {
  const DeviceStatus(this.availability, {this.message});
  const DeviceStatus.checking() : this(DeviceAvailability.checking);
  const DeviceStatus.online() : this(DeviceAvailability.online);
  const DeviceStatus.offline([String? message])
      : this(DeviceAvailability.offline, message: message);

  final DeviceAvailability availability;
  final String? message;
}
