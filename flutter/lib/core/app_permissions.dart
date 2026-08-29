import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Permission states used by onboarding so transport failures are not shown
/// while iOS is presenting its Local Network prompt.
enum AppPermissionState {
  unknown,
  requestingPermission,
  granted,
  denied,
  restricted,
  unavailable,
}

bool shouldShowLocalNetworkSettingsAction(AppPermissionState state) =>
    state == AppPermissionState.denied ||
    state == AppPermissionState.restricted;

class LocalNetworkPermissionService {
  const LocalNetworkPermissionService({this.channel, this.isIOS});

  static const _channelName = 'shadowplay/local_network';

  final MethodChannel? channel;
  final bool? isIOS;

  /// Requests local-network access through the iOS Network framework bridge.
  ///
  /// iOS has no public requestLocalNetworkPermission API. The native bridge
  /// starts an NWBrowser for a declared Bonjour service, which is a real local
  /// network operation and lets iOS present its first-run alert. Android does
  /// not need this trigger; its LAN behavior is covered by the manifest and
  /// cleartext policy.
  Future<AppPermissionState> requestLocalNetworkAccess() async {
    if (!(isIOS ?? Platform.isIOS)) return AppPermissionState.granted;
    try {
      final value = await (channel ?? const MethodChannel(_channelName))
          .invokeMethod<String>('requestAccess')
          .timeout(const Duration(seconds: 10));
      return switch (value) {
        'granted' => AppPermissionState.granted,
        'denied' => AppPermissionState.denied,
        'restricted' => AppPermissionState.restricted,
        _ => AppPermissionState.unavailable,
      };
    } on MissingPluginException {
      return AppPermissionState.unavailable;
    } on PlatformException {
      return AppPermissionState.unavailable;
    } on TimeoutException {
      return AppPermissionState.unavailable;
    }
  }

  Future<void> openSettings() async {
    if (!(isIOS ?? Platform.isIOS)) return;
    try {
      await (channel ?? const MethodChannel(_channelName))
          .invokeMethod<void>('openSettings');
    } on MissingPluginException {
      // A missing native bridge cannot be treated as a denial.
    } on PlatformException {
      // Settings is a best-effort recovery action.
    }
  }
}
