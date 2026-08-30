import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadowplay/core/app_permissions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('permission state starts as unknown and unknown is not a denial', () {
    expect(AppPermissionState.values.first, AppPermissionState.unknown);
    expect(
      shouldShowLocalNetworkSettingsAction(AppPermissionState.unknown),
      isFalse,
    );
    expect(
      shouldShowLocalNetworkSettingsAction(AppPermissionState.unavailable),
      isFalse,
    );
  });

  test('Settings action is limited to a genuine denial or restriction', () {
    expect(
      shouldShowLocalNetworkSettingsAction(AppPermissionState.denied),
      isTrue,
    );
    expect(
      shouldShowLocalNetworkSettingsAction(AppPermissionState.restricted),
      isTrue,
    );
    expect(
      shouldShowLocalNetworkSettingsAction(AppPermissionState.granted),
      isFalse,
    );
  });

  test('native bridge states map without treating failures as denied',
      () async {
    final channel = MethodChannel('shadowplay/test_local_network');
    String? response;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => response);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    final service =
        LocalNetworkPermissionService(channel: channel, isIOS: true);
    response = 'granted';
    expect(
        await service.requestLocalNetworkAccess(), AppPermissionState.granted);
    response = 'denied';
    expect(
        await service.requestLocalNetworkAccess(), AppPermissionState.denied);
    response = 'restricted';
    expect(
      await service.requestLocalNetworkAccess(),
      AppPermissionState.restricted,
    );
    response = 'unavailable';
    expect(
      await service.requestLocalNetworkAccess(),
      AppPermissionState.unavailable,
    );
  });

  test('non-iOS platforms do not invoke a local network permission API',
      () async {
    final service = LocalNetworkPermissionService(isIOS: false);
    expect(
        await service.requestLocalNetworkAccess(), AppPermissionState.granted);
  });
}
