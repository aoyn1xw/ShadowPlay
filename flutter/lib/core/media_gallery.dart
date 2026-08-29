import 'package:gal/gal.dart';

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
  const GalMediaGallery({this.album = 'ShadowPlay'});

  final String album;

  @override
  Future<void> saveVideo(String path) async {
    final toAlbum = album.isNotEmpty;
    var hasAccess = await Gal.hasAccess(toAlbum: toAlbum);
    if (!hasAccess) {
      hasAccess = await Gal.requestAccess(toAlbum: toAlbum);
    }
    if (!hasAccess) {
      throw const GalleryAccessDeniedException();
    }

    try {
      await Gal.putVideo(path, album: album);
    } on GalException catch (error) {
      throw GallerySaveException(
          'Could not save the clip to Photos/Gallery: ${error.type}');
    }
  }
}
