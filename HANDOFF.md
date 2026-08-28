# ShadowPlay LAN pairing handoff

## Current status

LAN pairing is confirmed working on the physical iPhone after disabling the
iPhone VPN. Safari returned the expected response from:

`http://192.168.0.201:5047/api/v1/health`

The VPN was routing or blocking the phone's local-LAN traffic.

## Confirmed Windows evidence

- ShadowPlay listens on `0.0.0.0:5047`.
- The running executable was `C:\Users\ayon1xw\Downloads\ShadowPlay-win-x64\ShadowPlay.exe`.
- The exact Private firewall rule matches that executable and TCP port 5047.
- The Wi-Fi profile was initially `Public`; it was changed to `Private`.
- Tailscale is `Private` but has `NoTraffic` and must not count as the active LAN profile.

## Completed networking work

Commit `4ce35bc` contains the LAN diagnostics and pairing changes:

- Windows listener, selected-interface, firewall, and request logging.
- Private-only firewall rule detection/setup with UAC handling.
- Gateway-preferred QR IPv4 selection.
- Flutter health preflight before consuming the pairing code.
- Distinct timeout, refused, unreachable, HTTP, and malformed-response errors.
- Middleware, IP-selection, and Flutter pairing tests.

The uncommitted follow-up in `src/ShadowPlay.Windows/Services/WindowsFirewallService.cs`
fixes a diagnostic bug: `CurrentProfileTypes` included disconnected Private
Tailscale, so the UI could incorrectly say the Private rule was active while
Wi-Fi was Public. The new check requires an active traffic-carrying Private
profile.

## Permission-flow work started but not verified

`flutter/lib/features/onboarding/onboarding_flow.dart` now:

- Explains camera and Local Network permissions before pairing.
- Automatically runs `GET /api/v1/health` after a QR is scanned.
- Adds an explicit **Check PC connection** action for manual pairing.
- Keeps **Pair Device** disabled until health succeeds.

This file has not yet been formatted, analyzed, tested, or built after the
latest edit. Resume by running:

```powershell
cd C:\Users\ayon1xw\Documents\GitHub\ShadowPlay\flutter
dart format lib test
flutter analyze
flutter test --reporter expanded
flutter build apk --debug
```

Inspect the widget layout and test the QR/manual paths before keeping the
permission-flow change. In particular, verify that an asynchronous preflight
cannot update state after the page is disposed and that switching between QR
and manual modes resets stale preflight state.

## Previously verified before the latest permission edit

- `dotnet build src\ShadowPlay.Windows\ShadowPlay.Windows.csproj --configuration Release`: passed with 0 warnings/errors.
- `dotnet test ShadowPlay.sln --configuration Release`: 88 passed.
- `flutter analyze`: no issues.
- `flutter test`: 15 passed.
- `flutter build apk --debug`: successful.
- `.github/workflows/build.yml` already builds Android, performs an iOS PR compile check, and builds the signed iOS IPA on pushes/releases. Signing/OTA workflow was not changed.

## Resume test sequence

1. Finish and verify the permission-flow edit.
2. Build a new Windows artifact; the currently running Downloads copy may not contain the profile-check fix.
3. Keep the iPhone VPN disabled.
4. Confirm both devices are on the same non-guest Wi-Fi.
5. Open the health URL in iPhone Safari.
6. Scan a fresh QR code and confirm health succeeds before pairing.
7. If Safari times out while Windows has no `Incoming LAN request` log, investigate router/AP client isolation or guest-network separation.

Do not print or commit GitHub secrets, signing certificates, provisioning
profiles, bearer tokens, or pairing codes.
