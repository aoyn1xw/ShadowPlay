# Repository Guidelines

## Project Structure & Module Organization

ShadowPlay is a .NET 8 Windows desktop app with a Flutter mobile client.

- `src/ShadowPlay.Core/` contains UI-free clip monitoring, pairing, devices, settings, and networking logic.
- `src/ShadowPlay.Api/` contains the self-hosted LAN API, middleware, endpoints, and DTOs.
- `src/ShadowPlay.Windows/` contains the WPF/tray application, views, view models, and Windows services.
- `tests/ShadowPlay.Tests/` contains the xUnit unit and Kestrel integration tests.
- `flutter/lib/` contains the mobile app; `flutter/test/` contains Dart unit and widget tests.
- `.github/workflows/` contains CI, CodeQL, release, and signed iOS OTA workflows; `docs/` contains website assets.

## Build, Test, and Development Commands

Use the repository root for .NET commands and `flutter/` for Flutter commands.

```powershell
dotnet restore ShadowPlay.sln
dotnet build ShadowPlay.sln -c Release
dotnet test ShadowPlay.sln -c Release
dotnet format ShadowPlay.sln --verify-no-changes
dotnet run --project src/ShadowPlay.Windows -c Release
```

For the mobile client, install Flutter 3.47.2 and Java 17, then run `flutter pub get`, `flutter analyze`, `flutter test`, and `flutter build apk --debug`. Android builds require SDK platform 37. On macOS, validate iOS with `flutter build ios --release --no-codesign`.

## Coding Style & Naming Conventions

C# uses four-space indentation, nullable reference types, implicit usings, and the repository’s latest recommended .NET analyzers. Use PascalCase for types and public members, camelCase for locals and parameters, and clear structured logging templates. Dart code should follow `flutter_lints` and `dart format`. Keep features organized by module or screen.

## Testing Guidelines

Add xUnit tests under `tests/ShadowPlay.Tests/` and name methods descriptively; existing test methods use snake_case. API behavior should be tested through the real Kestrel setup where practical. Run `dotnet test` and `flutter test` for relevant changes; use `--collect:"XPlat Code Coverage"` or `flutter test --coverage` when coverage evidence is needed.

## Commit & Pull Request Guidelines

Use short, imperative commit subjects, for example `Sanitize request data before logging`. Pull requests should explain the behavior change, affected desktop/mobile surfaces, tests run, and any LAN, permissions, signing, or security implications. Link related issues and include screenshots or CI artifacts for UI or release changes. Do not commit credentials, signing material, pairing tokens, or generated build outputs.

## Security & Configuration Tips

The MVP uses bearer authentication over plain HTTP on the local network. Preserve private-network restrictions, never log unsanitized request data, and treat pairing tokens and user-provided paths as sensitive. Keep secrets in GitHub Actions secrets or local configuration outside source control.
