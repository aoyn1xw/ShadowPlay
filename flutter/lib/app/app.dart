import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/shell/main_shell.dart';

class ShadowPlayApp extends StatefulWidget {
  const ShadowPlayApp({required this.state, super.key});

  final AppState state;

  @override
  State<ShadowPlayApp> createState() => _ShadowPlayAppState();
}

class _ShadowPlayAppState extends State<ShadowPlayApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // Foreground/background transitions help correlate "it only happens in
    // the background" issues. Debug level keeps normal mode quiet.
    switch (lifecycle) {
      case AppLifecycleState.resumed:
        widget.state.diagnostics.debug('app', 'App resumed');
      case AppLifecycleState.paused:
        widget.state.diagnostics.debug('app', 'App paused');
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) => MaterialApp(
          title: 'ShadowPlay',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: widget.state.themeMode,
          home: widget.state.needsOnboarding
              ? OnboardingFlow(
                  state: widget.state,
                  onFinished: widget.state.completeOnboarding,
                )
              : MainShell(state: widget.state),
        ),
      );

  ThemeData _theme(Brightness brightness) {
    const seed = Color(0xFF76B900);
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.neutral,
    ).copyWith(
      primary: dark ? const Color(0xFFA0D65A) : const Color(0xFF416B12),
      onPrimary: dark ? const Color(0xFF152600) : Colors.white,
      primaryContainer:
          dark ? const Color(0xFF283A1C) : const Color(0xFFE1EED3),
      onPrimaryContainer:
          dark ? const Color(0xFFDDEDCB) : const Color(0xFF243B0C),
      surface: dark ? const Color(0xFF121413) : const Color(0xFFFAFBF8),
      surfaceContainerLow:
          dark ? const Color(0xFF1A1D1A) : const Color(0xFFF1F3EE),
      surfaceContainer:
          dark ? const Color(0xFF20231F) : const Color(0xFFEBEEE7),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: ThemeData(brightness: brightness)
            .textTheme
            .titleLarge
            ?.copyWith(
                color: scheme.onSurface,
                fontSize: 20,
                fontWeight: FontWeight.w600),
      ),
      dividerTheme: DividerThemeData(
          color: scheme.outlineVariant, thickness: 0.5, space: 1),
      listTileTheme: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 4)),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(48, 48))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)))),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        elevation: 0,
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: ThemeData(brightness: brightness)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
