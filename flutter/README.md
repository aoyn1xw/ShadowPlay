# ShadowPlay Flutter client

This is the cross-platform replacement for the reference client in `../ios/`.
It implements protocol v1 pairing, QR/manual pairing, secure token storage,
clip polling, persistent Documents-directory downloads, and local playback.
Pairing performs a `GET /api/v1/health` preflight before consuming the one-time
code and reports timeout, refused, unreachable, HTTP, and malformed-response
failures separately.

The UI uses a Material 3 onboarding flow and a persistent Home / Clips /
Settings navigation shell. Home is the offline library; Clips lists new files
from the paired PC and supports multi-select downloads. Normal playback never
streams from the PC.

## Bootstrap

Install Flutter 3.47.2 or a compatible stable release, then from this directory
run:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

On macOS, validate the unsigned iOS build with:

```shell
flutter build ios --release --no-codesign
```

## Platform configuration

The checked-in iOS project contains the camera and local-network privacy text,
the local-network ATS exception, and Keychain Sharing entitlements required by
`mobile_scanner` and `flutter_secure_storage`.

The checked-in Android manifest grants camera and internet access and allows
cleartext LAN traffic for the current HTTP v1 desktop API. The API is intended
for trusted home Wi-Fi; HTTP does not provide transport confidentiality.

GitHub Actions compiles the Android debug APK and unsigned iOS app during pull-request
validation without publishing those intermediate outputs. Version tags build the Android
release APK, while signed iOS distribution is handled separately by the repository's
[`ios-ota.yml`](../.github/workflows/ios-ota.yml) workflow. The unsigned iOS build must be
signed before it can be installed on a physical device.
