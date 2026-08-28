import 'package:flutter/widgets.dart';

import 'app/app.dart';
import 'core/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShadowPlayApp(state: await AppState.load()));
}
