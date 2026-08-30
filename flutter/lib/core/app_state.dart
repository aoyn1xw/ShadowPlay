import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_gallery.dart';
import 'models.dart';
import 'shadowplay_api.dart';

class AppState extends ChangeNotifier {
  AppState._(this._prefs, this._secureStorage, this._mediaGallery);

  static const _connectionsKey = 'connections';
  static const _activeServerKey = 'activeServerId';
  static const _onboardingKey = 'onboardingCompleted';
  static const _downloadsKey = 'downloadedClips';
  static const _themeKey = 'themeMode';
  static const _newClipNotificationsKey = 'newClipNotifications';
  static const _downloadNotificationsKey = 'downloadNotifications';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;
  final MediaGallery? _mediaGallery;

  List<Connection> connections = [];
  List<Clip> remoteClips = [];
  List<DownloadedClip> downloadedClips = [];
  final Map<String, DeviceStatus> deviceStatuses = {};
  final Map<String, double?> downloadProgress = {};
  final Map<String, String> downloadFailures = {};
  final Map<String, String> gallerySaveFailures = {};
  final Set<String> gallerySavedIds = {};

  String? activeServerId;
  String? _activeToken;
  String? clipLoadError;
  DateTime? lastSyncUtc;
  bool clipsLoading = false;
  bool onboardingCompleted = false;
  bool newClipNotifications = true;
  bool downloadNotifications = true;
  ThemeMode themeMode = ThemeMode.system;

  static Future<AppState> load() async {
    final state = AppState._(
      await SharedPreferences.getInstance(),
      const FlutterSecureStorage(),
      const GalMediaGallery(),
    );
    await state._restore();
    return state;
  }

  static AppState forTesting(
    SharedPreferences preferences, {
    List<Connection> connections = const [],
    List<Clip> remoteClips = const [],
    List<DownloadedClip> downloadedClips = const [],
    String? activeServerId,
    String? activeToken,
    bool onboardingCompleted = false,
    MediaGallery? mediaGallery,
  }) {
    final state =
        AppState._(preferences, const FlutterSecureStorage(), mediaGallery)
          ..connections = List.of(connections)
          ..remoteClips = List.of(remoteClips)
          ..downloadedClips = List.of(downloadedClips)
          ..activeServerId = activeServerId
          .._activeToken = activeToken
          ..onboardingCompleted = onboardingCompleted;
    return state;
  }

  Connection? get active {
    for (final connection in connections) {
      if (connection.serverId == activeServerId) return connection;
    }
    return null;
  }

  ShadowPlayApi? get api => active == null || _activeToken == null
      ? null
      : ShadowPlayApi(active!, _activeToken!);

  bool get needsOnboarding => connections.isEmpty || !onboardingCompleted;

  DeviceStatus get activeStatus => active == null
      ? const DeviceStatus.offline('No PC paired')
      : deviceStatuses[active!.serverId] ?? const DeviceStatus.checking();

  Set<String> get downloadedIds =>
      downloadedClips.map((clip) => clip.id).toSet();

  List<Clip> get newClips {
    final localIds = downloadedIds;
    return remoteClips.where((clip) => !localIds.contains(clip.id)).toList();
  }

  int get newClipCount => newClips.length;
  int get storageUsedBytes =>
      downloadedClips.fold(0, (sum, clip) => sum + clip.sizeBytes);
  bool get isDownloading => downloadProgress.isNotEmpty;

  Future<void> _restore() async {
    connections = (_prefs.getStringList(_connectionsKey) ?? const [])
        .map((item) =>
            Connection.fromJson(jsonDecode(item) as Map<String, dynamic>))
        .toList();
    activeServerId = _prefs.getString(_activeServerKey);
    if (active == null && connections.isNotEmpty) {
      activeServerId = connections.first.serverId;
    }
    if (active != null) {
      _activeToken = await _secureStorage.read(key: 'token_$activeServerId');
    }

    final restoredDownloads = (_prefs.getStringList(_downloadsKey) ?? const [])
        .map((item) =>
            DownloadedClip.fromJson(jsonDecode(item) as Map<String, dynamic>));
    downloadedClips = [
      for (final clip in restoredDownloads)
        if (await File(clip.localPath).exists()) clip,
    ];
    onboardingCompleted = _prefs.getBool(_onboardingKey) ?? false;
    newClipNotifications = _prefs.getBool(_newClipNotificationsKey) ?? true;
    downloadNotifications = _prefs.getBool(_downloadNotificationsKey) ?? true;
    themeMode = switch (_prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    await _saveDownloads();
  }

  Future<void> addPaired(
    Map<String, dynamic> response,
    String address,
    int port,
  ) async {
    final server =
        ServerInfo.fromJson(response['server'] as Map<String, dynamic>);
    final now = DateTime.now().toUtc();
    final connection = Connection(
      serverId: server.serverId,
      computerName: server.computerName,
      address: address,
      port: port,
      lastSeenUtc: now,
    );
    connections.removeWhere((item) => item.serverId == connection.serverId);
    connections.add(connection);
    activeServerId = connection.serverId;
    _activeToken = response['token'] as String;
    deviceStatuses[connection.serverId] = const DeviceStatus.online();
    await _secureStorage.write(
      key: 'token_$activeServerId',
      value: _activeToken,
    );
    await _saveConnections();
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    onboardingCompleted = true;
    await _prefs.setBool(_onboardingKey, true);
    notifyListeners();
  }

  Future<void> select(Connection connection) async {
    activeServerId = connection.serverId;
    _activeToken = await _secureStorage.read(key: 'token_$activeServerId');
    remoteClips = [];
    clipLoadError = null;
    await _saveConnections();
    notifyListeners();
    await refreshClips();
  }

  Future<void> forget(Connection connection) async {
    await _secureStorage.delete(key: 'token_${connection.serverId}');
    connections.removeWhere((item) => item.serverId == connection.serverId);
    deviceStatuses.remove(connection.serverId);
    if (activeServerId == connection.serverId) {
      activeServerId = connections.isEmpty ? null : connections.first.serverId;
      _activeToken = activeServerId == null
          ? null
          : await _secureStorage.read(key: 'token_$activeServerId');
      remoteClips = [];
    }
    await _saveConnections();
    notifyListeners();
    if (active != null) await refreshClips();
  }

  Future<void> refreshClips({bool silent = false}) async {
    final client = api;
    if (client == null) return;
    if (!silent) {
      clipsLoading = true;
      notifyListeners();
    }
    try {
      remoteClips = await client.clips();
      clipLoadError = null;
      lastSyncUtc = DateTime.now().toUtc();
      active!.lastSeenUtc = lastSyncUtc;
      deviceStatuses[active!.serverId] = const DeviceStatus.online();
      await _saveConnections();
    } catch (error) {
      clipLoadError = error.toString();
      deviceStatuses[active!.serverId] = DeviceStatus.offline(error.toString());
    } finally {
      clipsLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshDeviceStatuses() async {
    for (final connection in connections) {
      deviceStatuses[connection.serverId] = const DeviceStatus.checking();
    }
    notifyListeners();
    await Future.wait(connections.map((connection) async {
      try {
        final token =
            await _secureStorage.read(key: 'token_${connection.serverId}');
        if (token == null) {
          throw const ApiException('Pairing token is missing.');
        }
        final info = await ShadowPlayApi(connection, token).serverInfo();
        connection.computerName = info.computerName;
        connection.lastSeenUtc = DateTime.now().toUtc();
        deviceStatuses[connection.serverId] = const DeviceStatus.online();
      } catch (error) {
        deviceStatuses[connection.serverId] =
            DeviceStatus.offline(error.toString());
      }
    }));
    await _saveConnections();
    notifyListeners();
  }

  Future<void> downloadClips(Iterable<Clip> clips,
      {int maxConcurrent = 2}) async {
    final pending =
        clips.where((clip) => !downloadedIds.contains(clip.id)).toList();
    if (pending.isEmpty) return;

    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (index >= pending.length) break;
        final clip = pending[index++];
        await _downloadClip(clip);
      }
    }

    final workerCount =
        pending.length < maxConcurrent ? pending.length : maxConcurrent;
    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);
  }

  Future<void> _downloadClip(Clip clip) async {
    final client = api;
    if (client == null) return;
    downloadFailures.remove(clip.id);
    gallerySaveFailures.remove(clip.id);
    gallerySavedIds.remove(clip.id);
    downloadProgress[clip.id] = null;
    notifyListeners();

    IOSink? sink;
    File? partialFile;
    try {
      final directory = await getApplicationDocumentsDirectory();
      final safeName = clip.fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final prefix = clip.id.length >= 8 ? clip.id.substring(0, 8) : clip.id;
      final finalFile =
          File('${directory.path}${Platform.pathSeparator}${prefix}_$safeName');
      partialFile = File('${finalFile.path}.part');
      if (await partialFile.exists()) await partialFile.delete();

      final response = await client.startDownload(clip);
      sink = partialFile.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        final total = response.contentLength;
        downloadProgress[clip.id] =
            total == null || total == 0 ? null : received / total;
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (await finalFile.exists()) await finalFile.delete();
      await partialFile.rename(finalFile.path);
      downloadedClips.removeWhere((item) => item.id == clip.id);
      downloadedClips.insert(0, DownloadedClip.fromRemote(clip, finalFile));
      downloadProgress.remove(clip.id);
      await _saveDownloads();

      final gallery = _mediaGallery;
      if (gallery != null) {
        try {
          await gallery.saveVideo(finalFile.path);
          gallerySavedIds.add(clip.id);
          gallerySaveFailures.remove(clip.id);
        } on GalleryAccessDeniedException catch (error) {
          gallerySaveFailures[clip.id] = error.toString();
        } on GallerySaveException catch (error) {
          gallerySaveFailures[clip.id] = error.toString();
        } catch (error) {
          gallerySaveFailures[clip.id] =
              'Could not save the clip to Photos/Gallery: $error';
        }
      }
    } catch (error) {
      await sink?.close();
      if (partialFile != null && await partialFile.exists()) {
        await partialFile.delete();
      }
      downloadProgress.remove(clip.id);
      downloadFailures[clip.id] = error.toString();
    }
    notifyListeners();
  }

  /// Retries exporting an already-downloaded clip to the platform gallery.
  /// The local playback copy is retained even when export is denied or fails.
  Future<bool> saveClipToGallery(DownloadedClip clip) async {
    final gallery = _mediaGallery;
    if (gallery == null) return false;
    try {
      await gallery.saveVideo(clip.localPath);
      gallerySavedIds.add(clip.id);
      gallerySaveFailures.remove(clip.id);
      notifyListeners();
      return true;
    } on GalleryAccessDeniedException catch (error) {
      gallerySaveFailures[clip.id] = error.toString();
    } on GallerySaveException catch (error) {
      gallerySaveFailures[clip.id] = error.toString();
    } catch (error) {
      gallerySaveFailures[clip.id] =
          'Could not save the clip to Photos/Gallery: $error';
    }
    notifyListeners();
    return false;
  }

  Future<void> clearDownloadedClips() async {
    for (final clip in downloadedClips) {
      final file = File(clip.localPath);
      if (await file.exists()) await file.delete();
    }
    downloadedClips = [];
    downloadFailures.clear();
    gallerySaveFailures.clear();
    gallerySavedIds.clear();
    await _saveDownloads();
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    await _prefs.setString(_themeKey, mode.name);
    notifyListeners();
  }

  Future<void> setNewClipNotifications(bool value) async {
    newClipNotifications = value;
    await _prefs.setBool(_newClipNotificationsKey, value);
    notifyListeners();
  }

  Future<void> setDownloadNotifications(bool value) async {
    downloadNotifications = value;
    await _prefs.setBool(_downloadNotificationsKey, value);
    notifyListeners();
  }

  Future<void> _saveConnections() async {
    await _prefs.setStringList(
      _connectionsKey,
      connections.map((item) => jsonEncode(item.toJson())).toList(),
    );
    if (activeServerId == null) {
      await _prefs.remove(_activeServerKey);
    } else {
      await _prefs.setString(_activeServerKey, activeServerId!);
    }
  }

  Future<void> _saveDownloads() async {
    await _prefs.setStringList(
      _downloadsKey,
      downloadedClips.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }
}
