import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_gallery.dart';
import 'diagnostics.dart';
import 'models.dart';
import 'resumable_download.dart';
import 'shadowplay_api.dart';

class AppState extends ChangeNotifier {
  AppState._(
    this._prefs,
    this._secureStorage,
    this._mediaGallery, {
    Diagnostics? diagnostics,
    ShadowPlayApi Function(Connection, String)? apiFactory,
  })  : diagnostics = diagnostics ?? Diagnostics(),
        _apiFactory = apiFactory;

  static const _connectionsKey = 'connections';
  static const _activeServerKey = 'activeServerId';
  static const _onboardingKey = 'onboardingCompleted';
  static const _downloadsKey = 'downloadedClips';
  static const _themeKey = 'themeMode';
  static const _newClipNotificationsKey = 'newClipNotifications';
  static const _downloadNotificationsKey = 'downloadNotifications';
  static const _verboseDiagnosticsKey = 'diagnosticsVerbose';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;
  final MediaGallery? _mediaGallery;

  /// Local, redacted diagnostic log. Buffers in memory until main() attaches
  /// storage; unit tests get a memory-only instance.
  final Diagnostics diagnostics;

  /// Test seam: override the transport used for a connection/token pair.
  final ShadowPlayApi Function(Connection, String)? _apiFactory;

  List<Connection> connections = [];
  List<Clip> remoteClips = [];
  List<DownloadedClip> downloadedClips = [];

  final Map<String, ServerInfo> serverInfos = {};

  /// Thumbnails and in-flight thumbnail requests, keyed per device.
  final Map<String, Uint8List> thumbnailCache = {};
  final Set<String> unavailableThumbnails = {};
  final Map<String, Future<Uint8List?>> _thumbnailRequests = {};

  /// Download state, keyed per device: `serverId|clipId`.
  final Map<String, double?> downloadProgress = {};
  final Map<String, String> downloadFailures = {};

  /// Gallery state is keyed by clip id (local-file identity).
  final Map<String, String> gallerySaveFailures = {};
  final Set<String> gallerySavedIds = {};

  final Map<String, CancelToken> _activeDownloadTokens = {};
  final Map<String, http.Client> _thumbnailClients = {};

  /// In-memory token cache so device switches do not depend on the plugin.
  final Map<String, String?> _tokenCache = {};

  /// Monotonic guard: only the newest refresh may publish results.
  int _refreshGeneration = 0;

  String? activeServerId;
  String? _activeToken;
  String? clipLoadError;
  DateTime? lastSyncUtc;
  bool clipsLoading = false;
  bool onboardingCompleted = false;
  bool newClipNotifications = true;
  bool downloadNotifications = true;
  bool isVerboseDiagnostics = false;
  ThemeMode themeMode = ThemeMode.system;

  static Future<AppState> load({required Diagnostics diagnostics}) async {
    final state = AppState._(
      await SharedPreferences.getInstance(),
      const FlutterSecureStorage(),
      const GalMediaGallery(),
      diagnostics: diagnostics,
    );
    await state._restore();
    state.diagnostics.info('app', 'Session restored', {
      'pcs': state.connections.length,
      'downloads': state.downloadedClips.length,
      'platform': Platform.operatingSystem,
    });
    return state;
  }

  static AppState forTesting(
    SharedPreferences preferences, {
    List<Connection> connections = const [],
    List<Clip> remoteClips = const [],
    List<DownloadedClip> downloadedClips = const [],
    String? activeServerId,
    String? activeToken,
    Map<String, String> tokens = const {},
    bool onboardingCompleted = false,
    MediaGallery? mediaGallery,
    FlutterSecureStorage? secureStorage,
    Diagnostics? diagnostics,
    ShadowPlayApi Function(Connection, String)? apiFactory,
  }) {
    final state = AppState._(
      preferences,
      secureStorage ?? const FlutterSecureStorage(),
      mediaGallery,
      diagnostics: diagnostics,
      apiFactory: apiFactory,
    )
      ..connections = List.of(connections)
      ..remoteClips = List.of(remoteClips)
      ..downloadedClips = List.of(downloadedClips)
      ..activeServerId = activeServerId
      .._activeToken = activeToken
      ..onboardingCompleted = onboardingCompleted;
    for (final entry in tokens.entries) {
      state._tokenCache[entry.key] = entry.value;
    }
    if (activeToken != null && activeServerId != null) {
      state._tokenCache[activeServerId] = activeToken;
    }
    return state;
  }

  // ------------------------------------------------------------- accessors

  Connection? get active {
    for (final connection in connections) {
      if (connection.serverId == activeServerId) return connection;
    }
    return null;
  }

  ShadowPlayApi? get api {
    final connection = active;
    final token = _activeToken;
    if (connection == null || token == null) return null;
    return _apiFactory?.call(connection, token) ??
        ShadowPlayApi(connection, token);
  }

  bool get needsOnboarding => connections.isEmpty || !onboardingCompleted;

  DeviceStatus get activeStatus => active == null
      ? const DeviceStatus.offline('No PC paired')
      : deviceStatuses[active!.serverId] ?? const DeviceStatus.checking();

  final Map<String, DeviceStatus> deviceStatuses = {};

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

  /// Per-device key helpers. Downloads are scoped to the PC they came from so
  /// overlapping transfers across devices cannot bleed into each other.
  static String deviceKey(String? serverId, String clipId) =>
      '${serverId ?? ''}|$clipId';

  double? getProgress(Connection? device, String clipId) =>
      downloadProgress[deviceKey(device?.serverId ?? activeServerId, clipId)];

  String? getFailure(Connection? device, String clipId) =>
      downloadFailures[deviceKey(device?.serverId ?? activeServerId, clipId)];

  bool isDownloadingClip(String clipId) =>
      downloadProgress.containsKey(deviceKey(activeServerId, clipId));

  bool isFailedClip(String clipId) =>
      downloadFailures.containsKey(deviceKey(activeServerId, clipId));

  bool hasDownloaded(String clipId) => downloadedIds.contains(clipId);

  // ---------------------------------------------------------------- restore

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
      _activeToken = await _tokenFor(active!.serverId);
    }

    final restoredDownloads = (_prefs.getStringList(_downloadsKey) ?? const [])
        .map((item) =>
            DownloadedClip.fromJson(jsonDecode(item) as Map<String, dynamic>));
    downloadedClips = [
      for (final clip in restoredDownloads)
        if (await File(clip.localPath).exists()) clip,
    ];
    await _cleanupStagedFiles();
    onboardingCompleted = _prefs.getBool(_onboardingKey) ?? false;
    newClipNotifications = _prefs.getBool(_newClipNotificationsKey) ?? true;
    downloadNotifications = _prefs.getBool(_downloadNotificationsKey) ?? true;
    themeMode = switch (_prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    isVerboseDiagnostics = _prefs.getBool(_verboseDiagnosticsKey) ?? false;
    diagnostics.applyVerbose(isVerboseDiagnostics);
    await _saveDownloads();
  }

  /// Removes leftover published-but-not-renamed files from interrupted runs.
  /// `.part` files are deliberately kept: they are resumable prefix data.
  Future<void> _cleanupStagedFiles() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            entity.path.endsWith('.staged') &&
            entity.path.endsWith('.part.staged') == false) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Cleanup is best-effort; never block startup.
    }
  }

  // ---------------------------------------------------------------- pairing

  Future<void> addPaired(
    Map<String, dynamic> response,
    String address,
    int port, {
    int? httpsPort,
    String? certSha256,
  }) async {
    final server =
        ServerInfo.fromJson(response['server'] as Map<String, dynamic>);

    if (httpsPort != null && certSha256 != null && certSha256.isNotEmpty) {
      // Trust consistency: when the QR carried a fingerprint, the server must
      // present the same certificate. A mismatch means a different host took
      // over the address; refuse to pair and never downgrade to TCP+HTTP.
      final advertised = normalizeFingerprint(server.httpsCertSha256);
      final qrPin = normalizeFingerprint(certSha256);
      if (advertised != null && qrPin != null && advertised != qrPin) {
        diagnostics.error('pairing',
            'Pairing refused: PC certificate does not match the QR pin');
        throw const ApiException(
          'The PC presented a different certificate than the QR code. Do not pair over this network; rescan the QR on the PC.',
          kind: ApiFailureKind.tlsUntrusted,
        );
      }
    }

    final now = DateTime.now().toUtc();
    final connection = Connection(
      serverId: server.serverId,
      computerName: server.computerName,
      address: address,
      port: port,
      lastSeenUtc: now,
      httpsPort: httpsPort,
      certSha256: certSha256,
    );
    connections.removeWhere((item) => item.serverId == connection.serverId);
    connections.add(connection);
    activeServerId = connection.serverId;
    _activeToken = response['token'] as String;
    _tokenCache[connection.serverId] = _activeToken;
    serverInfos[connection.serverId] = server;
    deviceStatuses[connection.serverId] = const DeviceStatus.online();
    // Adoption from the pairing response (manual mode, TOFU) when the QR did
    // not carry a pin.
    _adoptServerTls(connection, server);
    await _secureStorage.write(
      key: 'token_$activeServerId',
      value: _activeToken,
    );
    await _saveConnections();
    diagnostics.info('pairing', 'PC paired', {
      'pc': server.computerName,
      'pc id': shortId(connection.serverId),
      'transport':
          connection.usesTls ? 'HTTPS with pinned certificate' : 'HTTP',
    });
    notifyListeners();
  }

  /// Upgrades a legacy HTTP connection with the pinned-TLS details advertised
  /// by the server. Adoption only ever ADDS trust; an already-pinned
  /// connection is never modified (no silent downgrade, no silent re-pin).
  void _adoptServerTls(Connection connection, ServerInfo info) {
    if (connection.usesTls) return;
    final pin = normalizeFingerprint(info.httpsCertSha256);
    final tlsPort = info.httpsPort;
    if (pin == null || tlsPort == null || tlsPort <= 0) return;
    connection
      ..httpsPort = tlsPort
      ..certSha256 = pin;
  }

  Future<void> completeOnboarding() async {
    onboardingCompleted = true;
    await _prefs.setBool(_onboardingKey, true);
    diagnostics.info('app', 'Onboarding completed');
    notifyListeners();
  }

  // ------------------------------------------------------------- selection

  Future<void> select(Connection connection) async {
    activeServerId = connection.serverId;
    _activeToken = await _tokenFor(connection.serverId);
    diagnostics.debug('network', 'Active PC switched', {
      'pc': connection.computerName,
      'pc id': shortId(connection.serverId),
    });
    remoteClips = [];
    clipLoadError = null;
    await _saveConnections();
    notifyListeners();
    await refreshClips();
  }

  Future<void> forget(Connection connection) async {
    await _secureStorage.delete(key: 'token_${connection.serverId}');
    _tokenCache.remove(connection.serverId);
    cancelTransfersForDevice(connection.serverId);
    _closeThumbnailClient(connection.serverId);
    connections.removeWhere((item) => item.serverId == connection.serverId);
    deviceStatuses.remove(connection.serverId);
    serverInfos.remove(connection.serverId);
    diagnostics.info('pairing', 'PC forgotten', {
      'pc': connection.computerName,
      'pc id': shortId(connection.serverId),
    });
    if (activeServerId == connection.serverId) {
      activeServerId = connections.isEmpty ? null : connections.first.serverId;
      _activeToken =
          activeServerId == null ? null : await _tokenFor(activeServerId!);
      remoteClips = [];
    }
    await _saveConnections();
    notifyListeners();
    if (active != null) await refreshClips();
  }

  // ------------------------------------------------------------- refreshing

  Future<void> refreshClips({bool silent = false}) async {
    final client = api;
    if (client == null) return;
    final generation = ++_refreshGeneration;
    final connection = client.connection;

    if (!silent) {
      clipsLoading = true;
      notifyListeners();
    }
    try {
      final info = await client.serverInfo();
      final clips = await client.clips();

      // A newer refresh (or a device switch) supersedes this one entirely.
      if (generation != _refreshGeneration ||
          activeServerId != connection.serverId) {
        return;
      }
      serverInfos[connection.serverId] = info;
      remoteClips = clips;
      clipLoadError = null;
      lastSyncUtc = DateTime.now().toUtc();
      connection.lastSeenUtc = lastSyncUtc;
      deviceStatuses[connection.serverId] = const DeviceStatus.online();
      diagnostics.info('network', 'Clip list refreshed', {
        'pc': info.computerName,
        'clips': clips.length,
      });
      _adoptServerTls(connection, info);
      await _saveConnections();
    } catch (error) {
      if (generation != _refreshGeneration ||
          activeServerId != connection.serverId) {
        return;
      }
      clipLoadError = error.toString();
      deviceStatuses[connection.serverId] =
          DeviceStatus.offline(error.toString());
      diagnostics.warning('network', 'Clip refresh failed', {
        'pc': connection.computerName,
        'error': error.toString(),
      });
    } finally {
      // Only the latest refresh clears shared loading state.
      if (generation == _refreshGeneration) {
        clipsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshDeviceStatuses() async {
    for (final connection in connections) {
      deviceStatuses[connection.serverId] = const DeviceStatus.checking();
    }
    notifyListeners();
    await Future.wait(connections.map((connection) async {
      try {
        final token = await _tokenFor(connection.serverId);
        if (token == null) {
          throw const ApiException('Pairing token is missing.');
        }
        final info = await ShadowPlayApi(connection, token).serverInfo();
        serverInfos[connection.serverId] = info;
        connection.computerName = info.computerName;
        connection.lastSeenUtc = DateTime.now().toUtc();
        deviceStatuses[connection.serverId] = const DeviceStatus.online();
        _adoptServerTls(connection, info);
        diagnostics.debug('network', 'PC reachable', {
          'pc': info.computerName,
          'pc id': shortId(connection.serverId),
        });
      } catch (error) {
        deviceStatuses[connection.serverId] =
            DeviceStatus.offline(error.toString());
        diagnostics.warning('network', 'PC unreachable', {
          'pc': connection.computerName,
          'error': error.toString(),
        });
      }
    }));
    await _saveConnections();
    notifyListeners();
  }

  // ------------------------------------------------------------- thumbnails

  /// Transport for thumbnail requests, pooled per device to avoid one
  /// connection per row.
  http.Client _thumbnailTransport(String serverId) {
    final existing = _thumbnailClients[serverId];
    if (existing != null) return existing;
    final connection = connections.firstWhere((c) => c.serverId == serverId);
    final client = ShadowPlayApi.transportClient(connection);
    _thumbnailClients[serverId] = client;
    return client;
  }

  void _closeThumbnailClient(String serverId) {
    final client = _thumbnailClients.remove(serverId);
    client?.close();
  }

  Future<Uint8List?> loadThumbnail(Clip clip) {
    final client = api;
    if (client == null) return Future.value(null);
    final serverId = client.connection.serverId;
    final url = clip.thumbnailUrl;
    if (url == null) return Future.value(null);

    final key = '$serverId|${clip.id}:${clip.sizeBytes}:'
        '${clip.lastWriteTimeUtc.toIso8601String()}';
    final cached = thumbnailCache[key];
    if (cached != null) return Future.value(cached);
    if (unavailableThumbnails.contains(key)) return Future.value(null);
    final existing = _thumbnailRequests[key];
    if (existing != null) return existing;

    final transport = _thumbnailTransport(serverId);
    // NOTE: client is captured here so a device switch mid-flight can never
    // attach this request's bytes to another PC's token.
    final request = () async {
      try {
        final bytes = await client.thumbnail(clip, client: transport);
        if (bytes.isEmpty) {
          unavailableThumbnails.add(key);
          return null;
        }
        final bits = Uint8List.fromList(bytes);
        thumbnailCache[key] = bits;
        return bits;
      } on ApiException catch (error) {
        if (error.statusCode == 404) unavailableThumbnails.add(key);
        return null;
      } catch (_) {
        return null;
      } finally {
        _thumbnailRequests.remove(key);
      }
    }();
    _thumbnailRequests[key] = request;
    return request;
  }

  // -------------------------------------------------------------- downloads

  Future<void> downloadClips(Iterable<Clip> clips,
      {int maxConcurrent = 2}) async {
    final client = api;
    if (client == null) return;
    // The whole batch belongs to the connection captured now; later device
    // switches must not repurpose these transfers.
    final connection = client.connection;
    final downloaded = downloadedIds;
    final downloading = downloadProgress.keys.toSet();
    final targets = [
      for (final clip in clips)
        if (!downloaded.contains(clip.id) &&
            !downloading.contains(deviceKey(connection.serverId, clip.id)))
          clip,
    ];
    if (targets.isEmpty) return;
    final batchToken = client.token;

    _closeFailureEntries(connection.serverId, targets);
    for (final clip in targets) {
      downloadProgress[deviceKey(connection.serverId, clip.id)] = null;
      _activeDownloadTokens.putIfAbsent(
        deviceKey(connection.serverId, clip.id),
        () => CancelToken(),
      );
    }
    notifyListeners();

    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (index >= targets.length) break;
        final clip = targets[index++];
        final token =
            _activeDownloadTokens[deviceKey(connection.serverId, clip.id)];
        if (token != null && token.cancelled) {
          downloadProgress.remove(deviceKey(connection.serverId, clip.id));
          continue;
        }
        await _downloadClip(connection, clip, token, batchToken);
      }
    }

    final workerCount =
        targets.length < maxConcurrent ? targets.length : maxConcurrent;
    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);
    notifyListeners();
  }

  void _closeFailureEntries(String serverId, Iterable<Clip> targets) {
    for (final clip in targets) {
      final key = deviceKey(serverId, clip.id);
      downloadFailures.remove(key);
      gallerySaveFailures.remove(clip.id);
      gallerySavedIds.remove(clip.id);
    }
  }

  Future<void> _downloadClip(
    Connection connection,
    Clip clip,
    CancelToken? cancelToken,
    String apiToken,
  ) async {
    final serverId = connection.serverId;
    final key = deviceKey(serverId, clip.id);
    final token = cancelToken ?? CancelToken();
    _activeDownloadTokens[key] = token;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final safeName = clip.fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final prefix = clip.id.length >= 8 ? clip.id.substring(0, 8) : clip.id;
      final finalFile =
          File('${directory.path}${Platform.pathSeparator}${prefix}_$safeName');
      final partFile = File('${finalFile.path}.part');
      final stagedFile = File('${finalFile.path}.staged');

      var lastProgressStep = -1;
      final downloader = ResumableDownloader(
        openSegment: (rangeStart) => ShadowPlayApi(connection, apiToken)
            .openDownload(clip, rangeStart: rangeStart),
        partFile: partFile,
        expectedSize: clip.sizeBytes,
        onProgress: (fraction) {
          downloadProgress[key] = fraction;
          notifyListeners();
          // Quarter-way checkpoints turn a transfer into a readable trace
          // without logging every network chunk.
          final step = (fraction * 4).floor();
          if (step > lastProgressStep) {
            lastProgressStep = step;
            diagnostics.debug('download', 'Download progress', {
              'clip': clip.fileName,
              'percent': (fraction * 100).round(),
            });
          }
        },
        cancelToken: token,
        progressThrottle: ProgressThrottle(),
      );

      diagnostics.info('download', 'Download started', {
        'clip': clip.fileName,
        'size': clip.sizeBytes,
        'pc': connection.computerName,
      });
      final result = await downloader.download();

      switch (result.outcome) {
        case DownloadOutcome.cancelled:
          downloadProgress.remove(key);
          diagnostics.info('download', 'Download cancelled', {
            'clip': clip.fileName,
            'pc id': shortId(connection.serverId),
          });
          break;
        case DownloadOutcome.failed:
          downloadProgress.remove(key);
          downloadFailures[key] = result.errorText ?? 'Download failed.';
          diagnostics.warning('download', 'Download failed', {
            'clip': clip.fileName,
            'error': result.errorText ?? 'Download failed.',
          });
          break;
        case DownloadOutcome.success:
          downloadProgress.remove(key);
          downloadFailures.remove(key);
          diagnostics.info('download', 'Download finished', {
            'clip': clip.fileName,
            'size': clip.sizeBytes,
          });
          // Publish atomically-ish: the replacement has been fully verified,
          // so only now may the previous copy be replaced.
          await _publishDownload(clip, partFile, stagedFile, finalFile);
          await _saveDownloads();
          await _exportToGallery(clip, finalFile);
          break;
      }
    } catch (error) {
      downloadProgress.remove(key);
      downloadFailures[key] = error.toString();
      diagnostics.error('download', 'Download interrupted', {
        'clip': clip.fileName,
        'pc id': shortId(connection.serverId),
        'error': error.toString(),
      });
    } finally {
      _activeDownloadTokens.remove(key);
      notifyListeners();
    }
  }

  Future<void> _publishDownload(
    Clip clip,
    File partFile,
    File stagedFile,
    File finalFile,
  ) async {
    // Stage the verified part under its final name so a crash between the
    // delete and rename can never lose the bytes twice over.
    if (await stagedFile.exists()) {
      try {
        await stagedFile.delete();
      } catch (_) {}
    }
    try {
      await partFile.rename(stagedFile.path);
    } catch (error) {
      throw 'Could not finalize the download: $error';
    }
    if (await finalFile.exists()) {
      try {
        await finalFile.delete();
      } catch (error) {
        // Old copy survives the failed delete (kept intentionally).
        try {
          await stagedFile.delete();
        } catch (_) {}
        throw 'Could not replace the existing download: $error';
      }
    }
    try {
      await stagedFile.rename(finalFile.path);
    } catch (error) {
      throw 'Could not place the finished download: $error';
    }

    downloadedClips.removeWhere((item) => item.id == clip.id);
    downloadedClips.insert(0, DownloadedClip.fromRemote(clip, finalFile));
  }

  Future<void> _exportToGallery(Clip clip, File finalFile) async {
    final gallery = _mediaGallery;
    if (gallery == null) return;
    final fileLabel = fileNameOf(finalFile.path);
    try {
      await gallery.saveVideo(finalFile.path);
      gallerySavedIds.add(clip.id);
      gallerySaveFailures.remove(clip.id);
      diagnostics
          .info('gallery', 'Saved clip to Photos/Gallery', {'clip': fileLabel});
    } on GalleryAccessDeniedException catch (error) {
      gallerySaveFailures[clip.id] = error.toString();
      diagnostics.warning('gallery', 'Photos/Gallery permission denied',
          {'clip': fileLabel, 'error': error.toString()});
    } on GallerySaveException catch (error) {
      gallerySaveFailures[clip.id] = error.toString();
      diagnostics.warning('gallery', 'Photos/Gallery save failed',
          {'clip': fileLabel, 'error': error.toString()});
    } catch (error) {
      gallerySaveFailures[clip.id] =
          'Could not save the clip to Photos/Gallery: $error';
      diagnostics.warning('gallery', 'Photos/Gallery save failed',
          {'clip': fileLabel, 'error': error.toString()});
    }
  }

  /// Cancels one active (or queued) transfer. Interrupted parts stay on disk
  /// so the next attempt resumes.
  void cancelDownload(String clipId) {
    final key = deviceKey(activeServerId, clipId);
    _activeDownloadTokens[key]?.cancelled = true;
  }

  /// Cancels every transfer belonging to [serverId].
  void cancelTransfersForDevice(String serverId) {
    for (final entry in _activeDownloadTokens.entries) {
      if (entry.key.startsWith('$serverId|')) {
        entry.value.cancelled = true;
      }
    }
    downloadProgress.removeWhere((key, _) => key.startsWith('$serverId|'));
  }

  // ---------------------------------------------------------------- library

  /// Retries exporting an already-downloaded clip to the platform gallery.
  /// The local playback copy is retained even when export is denied or fails.
  Future<bool> saveClipToGallery(DownloadedClip clip) async {
    final gallery = _mediaGallery;
    if (gallery == null) return false;
    final fileLabel = fileNameOf(clip.localPath);
    try {
      await gallery.saveVideo(clip.localPath);
      gallerySavedIds.add(clip.id);
      gallerySaveFailures.remove(clip.id);
      diagnostics
          .info('gallery', 'Saved clip to Photos/Gallery', {'clip': fileLabel});
      notifyListeners();
      return true;
    } on GalleryAccessDeniedException catch (error) {
      gallerySaveFailures[clip.id] = error.toString();
      diagnostics.warning('gallery', 'Photos/Gallery permission denied',
          {'clip': fileLabel, 'error': error.toString()});
    } on GallerySaveException catch (error) {
      gallerySaveFailures[clip.id] = error.toString();
      diagnostics.warning('gallery', 'Photos/Gallery save failed',
          {'clip': fileLabel, 'error': error.toString()});
    } catch (error) {
      gallerySaveFailures[clip.id] =
          'Could not save the clip to Photos/Gallery: $error';
      diagnostics.warning('gallery', 'Photos/Gallery save failed',
          {'clip': fileLabel, 'error': error.toString()});
    }
    notifyListeners();
    return false;
  }

  Future<void> deleteDownloadedClip(DownloadedClip clip) async {
    final file = File(clip.localPath);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    downloadedClips.removeWhere((item) => item.id == clip.id);
    downloadFailures.removeWhere((key, _) => key.endsWith('|${clip.id}'));
    gallerySaveFailures.remove(clip.id);
    gallerySavedIds.remove(clip.id);
    diagnostics.info('library', 'Downloaded clip removed',
        {'clip': fileNameOf(clip.localPath)});
    await _saveDownloads();
    notifyListeners();
  }

  Future<void> clearDownloadedClips() async {
    for (final token in _activeDownloadTokens.values) {
      token.cancelled = true;
    }
    for (final clip in downloadedClips) {
      final file = File(clip.localPath);
      if (await file.exists()) await file.delete();
    }
    downloadedClips = [];
    downloadFailures.clear();
    gallerySaveFailures.clear();
    gallerySavedIds.clear();
    diagnostics.info('library', 'All downloaded clips cleared from device');
    await _saveDownloads();
    notifyListeners();
  }

  // ------------------------------------------------------------- settings

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

  /// Verbose diagnostics mode: low-level events (debug severity) are recorded
  /// on top of the normal always-on info/warn/error stream.
  Future<void> setVerboseDiagnostics(bool value) async {
    if (isVerboseDiagnostics == value) return;
    isVerboseDiagnostics = value;
    diagnostics.applyVerbose(value);
    await _prefs.setBool(_verboseDiagnosticsKey, value);
    notifyListeners();
  }

  // ------------------------------------------------------------- storage

  Future<String?> _tokenFor(String serverId) async {
    if (_tokenCache.containsKey(serverId)) return _tokenCache[serverId];
    final value = await _secureStorage.read(key: 'token_$serverId');
    _tokenCache[serverId] = value;
    return value;
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
