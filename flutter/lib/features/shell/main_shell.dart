import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/app_state.dart';
import '../clips/clips_screen.dart';
import '../home/home_screen.dart';
import '../settings/settings_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({required this.state, super.key});
  final AppState state;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.state.refreshClips());
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => widget.state.refreshClips(silent: true),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.state.refreshClips(silent: true);
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pollTimer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _index,
            children: [
              HomeScreen(state: widget.state),
              ClipsScreen(state: widget.state),
              SettingsScreen(state: widget.state),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (index) {
            setState(() => _index = index);
            if (index == 1) widget.state.refreshClips(silent: true);
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Badge.count(
                count: widget.state.newClipCount,
                isLabelVisible: widget.state.newClipCount > 0,
                child: const Icon(Icons.video_library_outlined),
              ),
              selectedIcon: Badge.count(
                count: widget.state.newClipCount,
                isLabelVisible: widget.state.newClipCount > 0,
                child: const Icon(Icons.video_library),
              ),
              label: 'Clips',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      );
}
