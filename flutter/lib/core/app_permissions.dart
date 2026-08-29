import 'dart:async';
import 'dart:io';

/// Permission states used by onboarding so transport failures are not shown
/// while iOS is presenting its Local Network prompt.
enum AppPermissionState {
  idle,
  requestingPermission,
  granted,
  denied,
  unavailable,
}

class LocalNetworkPermissionService {
  const LocalNetworkPermissionService();

  /// Best-effort trigger for Apple's Local Network prompt.
  ///
  /// iOS does not expose a direct Local Network permission API. Sending a
  /// harmless one-byte mDNS multicast probe causes the OS prompt before the
  /// pairing health request. Android does not need this trigger; its LAN
  /// behavior is covered by the manifest permissions and cleartext policy.
  Future<AppPermissionState> requestLocalNetworkAccess() async {
    if (!Platform.isIOS) return AppPermissionState.granted;

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      ).timeout(const Duration(seconds: 3));
      socket.broadcastEnabled = true;
      final sent = socket.send(
        const [0],
        InternetAddress('224.0.0.251'),
        5353,
      );
      return sent > 0 ? AppPermissionState.granted : AppPermissionState.denied;
    } on TimeoutException {
      return AppPermissionState.unavailable;
    } on SocketException {
      return AppPermissionState.denied;
    } finally {
      socket?.close();
    }
  }
}
