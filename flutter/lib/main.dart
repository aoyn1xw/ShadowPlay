import 'dart:io';

import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'core/app_state.dart';
import 'core/diagnostics.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Diagnostics buffer in memory from the first line; file storage attaches
  // once the platform directory is known. Nothing is uploaded anywhere.
  final diagnostics = Diagnostics();
  diagnostics.info('app', 'ShadowPlay starting', {
    'platform': Platform.operatingSystem,
    'locale': Platform.localeName,
  });
  await diagnostics.attachDefault();
  runApp(ShadowPlayApp(state: await AppState.load(diagnostics: diagnostics)));
}
