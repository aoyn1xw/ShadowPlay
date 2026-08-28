import 'dart:io';

class Clip {
  const Clip({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.lastWriteTimeUtc,
  });

  factory Clip.fromJson(Map<String, dynamic> json) => Clip(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        lastWriteTimeUtc: DateTime.parse(json['lastWriteTimeUtc'] as String),
      );

  final String id;
  final String fileName;
  final int sizeBytes;
  final DateTime lastWriteTimeUtc;
}

class ServerInfo {
  const ServerInfo({
    required this.serverId,
    required this.computerName,
    required this.clipCount,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        serverId: json['serverId'] as String,
        computerName: json['computerName'] as String,
        clipCount: (json['clipCount'] as num?)?.toInt() ?? 0,
      );

  final String serverId;
  final String computerName;
  final int clipCount;
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
  });

  factory DownloadedClip.fromJson(Map<String, dynamic> json) => DownloadedClip(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        sizeBytes: (json['sizeBytes'] as num).toInt(),
        lastWriteTimeUtc: DateTime.parse(json['lastWriteTimeUtc'] as String),
        localPath: json['localPath'] as String,
      );

  factory DownloadedClip.fromRemote(Clip clip, File file) => DownloadedClip(
        id: clip.id,
        fileName: clip.fileName,
        sizeBytes: clip.sizeBytes,
        lastWriteTimeUtc: clip.lastWriteTimeUtc,
        localPath: file.path,
      );

  final String id;
  final String fileName;
  final int sizeBytes;
  final DateTime lastWriteTimeUtc;
  final String localPath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'sizeBytes': sizeBytes,
        'lastWriteTimeUtc': lastWriteTimeUtc.toIso8601String(),
        'localPath': localPath,
      };
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
