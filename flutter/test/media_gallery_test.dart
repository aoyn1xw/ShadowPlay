import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shadowplay/core/media_gallery.dart';

void main() {
  test('iOS prepared path is sent to Photos and cleaned up afterwards',
      () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('shadowplay-gallery-');
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final originalPath = '${temporaryDirectory.path}/original.mp4';
    await File(originalPath).writeAsString('original clip');
    final temporaryPath = '${temporaryDirectory.path}/prepared.mp4';
    await File(temporaryPath).writeAsString('temporary export');
    final savedPaths = <String>[];

    final gallery = GalMediaGallery(
      accessCheck: (_) async => true,
      iosVideoPreparer: (path) async {
        expect(path, originalPath);
        return temporaryPath;
      },
      videoSaver: (path, _) async => savedPaths.add(path),
    );

    await gallery.saveVideo(originalPath);

    expect(savedPaths, [temporaryPath]);
    expect(await File(originalPath).readAsString(), 'original clip');
    expect(await File(temporaryPath).exists(), isFalse);
  });

  test('temporary iOS export is cleaned up when Photos save fails', () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('shadowplay-gallery-');
    addTearDown(() => temporaryDirectory.delete(recursive: true));

    final temporaryPath = '${temporaryDirectory.path}/prepared.mp4';
    await File(temporaryPath).writeAsString('temporary export');
    final gallery = GalMediaGallery(
      accessCheck: (_) async => true,
      iosVideoPreparer: (_) async => temporaryPath,
      videoSaver: (_, __) async {
        throw const GallerySaveException('Photos import failed');
      },
    );

    await expectLater(
      gallery.saveVideo('original.mp4'),
      throwsA(
        isA<GallerySaveException>().having(
          (error) => error.message,
          'message',
          'Photos import failed',
        ),
      ),
    );
    expect(await File(temporaryPath).exists(), isFalse);
  });

  test('ordinary videos keep the original path', () async {
    final savedPaths = <String>[];
    final gallery = GalMediaGallery(
      accessCheck: (_) async => true,
      iosVideoPreparer: (path) async => path,
      videoSaver: (path, _) async => savedPaths.add(path),
    );

    await gallery.saveVideo('ordinary.mp4');

    expect(savedPaths, ['ordinary.mp4']);
  });
}
