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
      );

  final String serverId;
  final String computerName;
  final int clipCount;
  final String? serverVersion;
  final int apiVersion;
  final Set<String> capabilities;

  bool supports(String capability) => capabilities.contains(capability);
}

class PairingPayload {
  const PairingPayload({
    required this.serverId,
    required this.computerName,
    required this.address,
    required this.port,
    required this.code,
  });

  factory PairingPayload.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1) {
      throw const FormatException('Unsupported pairing protocol.');
    }
    return PairingPayload(
      serverId: json['serverId'] as String,
      computerName: json['computerName'] as String,
      address: json['lanAddress'] as String,
      port: (json['port'] as num).toInt(),
      code: json['pairingCode'] as String,
    );
  }

  final String serverId;
  final String computerName;
  final String address;
  final int port;
  final String code;
}

class Connection {
  Connection({
    required this.serverId,
    required this.computerName,
    required this.address,
    required this.port,
    this.lastSeenUtc,
  });

  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
        serverId: json['serverId'] as String,
        computerName: json['computerName'] as String,
        address: json['address'] as String,
        port: (json['port'] as num).toInt(),
        lastSeenUtc: json['lastSeenUtc'] == null
            ? null
            : DateTime.tryParse(json['lastSeenUtc'] as String),
      );

  final String serverId;
  String computerName;
  String address;
  int port;
  DateTime? lastSeenUtc;

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'computerName': computerName,
        'address': address,
        'port': port,
        'lastSeenUtc': lastSeenUtc?.toIso8601String(),
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
