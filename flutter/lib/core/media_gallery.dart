import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

typedef IosVideoPreparer = Future<String> Function(String path);
typedef VideoSaver = Future<void> Function(String path, String album);
typedef GalleryAccessCheck = Future<bool> Function(bool toAlbum);
typedef GalleryAccessRequest = Future<bool> Function(bool toAlbum);

/// Abstraction around the platform media library so downloads remain testable.
abstract interface class MediaGallery {
  Future<void> saveVideo(String path);
}

class GalleryAccessDeniedException implements Exception {
  const GalleryAccessDeniedException();

  @override
  String toString() => 'Photo/video library access was not granted.';
}

class GallerySaveException implements Exception {
  const GallerySaveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Saves videos to a ShadowPlay album on iOS Photos or Android Gallery.
class GalMediaGallery implements MediaGallery {
  const GalMediaGallery({
    this.album = 'ShadowPlay',
    this.iosVideoPreparer,
    this.videoSaver,
    this.accessCheck,
    this.accessRequest,
  });

  final String album;

  /// Optional seams for testing the iOS preparation and cleanup flow.
  /// Production callers leave these unset.
  final IosVideoPreparer? iosVideoPreparer;
  final VideoSaver? videoSaver;
  final GalleryAccessCheck? accessCheck;
  final GalleryAccessRequest? accessRequest;

  static const _iosExportChannel = MethodChannel('shadowplay/media');

  @override
  Future<void> saveVideo(String path) async {
    final toAlbum = album.isNotEmpty;
    var hasAccess = accessCheck == null
        ? await Gal.hasAccess(toAlbum: toAlbum)
        : await accessCheck!(toAlbum);
    if (!hasAccess) {
      hasAccess = accessRequest == null
          ? await Gal.requestAccess(toAlbum: toAlbum)
          : await accessRequest!(toAlbum);
    }
    if (!hasAccess) {
      throw const GalleryAccessDeniedException();
    }

    String? temporaryPath;
    try {
      final exportPath = await _preparePathForPhotos(path);
      if (exportPath != path && !_isPersistentDiagnosticPath(exportPath)) {
        temporaryPath = exportPath;
      }

      final shouldReportPhotosSave =
          exportPath != path && iosVideoPreparer == null && Platform.isIOS;
      if (shouldReportPhotosSave) {
        await _recordPhotosSaveResult(exportPath, status: 'started');
      }

      try {
        if (videoSaver != null) {
          await videoSaver!(exportPath, album);
        } else {
          await Gal.putVideo(exportPath, album: album);
        }
      } catch (error) {
        if (shouldReportPhotosSave) {
          await _recordPhotosSaveResult(
            exportPath,
            status: 'failure',
            error: error.toString(),
          );
        }
        rethrow;
      }

      if (shouldReportPhotosSave) {
        await _recordPhotosSaveResult(exportPath, status: 'success');
      }
    } on GalException catch (error) {
      throw GallerySaveException(
          'Could not save the clip to Photos/Gallery: ${error.type}');
    } on PlatformException catch (error) {
      throw GallerySaveException(
        'Could not prepare the clip for Photos: '
        '${error.message ?? error.code}',
      );
    } finally {
      if (temporaryPath != null) {
        try {
          await File(temporaryPath).delete();
        } on FileSystemException {
          // The exported copy is disposable; a cleanup failure must not
          // turn a successful Photos import into a reported save failure.
        }
      }
    }
  }

  Future<String> _preparePathForPhotos(String path) async {
    final preparer = iosVideoPreparer;
    if (preparer != null) return preparer(path);
    if (!Platform.isIOS) return path;

    final preparedPath = await _iosExportChannel.invokeMethod<String>(
      'prepareFullFrameRateVideo',
      <String, Object>{'path': path},
    );
    if (preparedPath == null || preparedPath.isEmpty) {
      throw const GallerySaveException(
        'Could not prepare the clip for Photos: iOS returned no export path.',
      );
    }
    return preparedPath;
  }

  Future<void> _recordPhotosSaveResult(
    String path, {
    required String status,
    String? error,
  }) async {
    try {
      await _iosExportChannel.invokeMethod<void>(
        'recordPhotosSaveResult',
        <String, Object?>{
          'path': path,
          'status': status,
          if (error != null) 'error': error,
        },
      );
    } on MissingPluginException {
      // Diagnostics are best-effort and must not affect Photos saving.
    } on PlatformException {
      // Diagnostics are best-effort and must not affect Photos saving.
    }
  }

  bool _isPersistentDiagnosticPath(String path) {
    return Platform.isIOS && path.contains('/ShadowPlayDiagnostics/');
  }
}
