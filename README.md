# ShadowPlay (working title)

A lightweight Windows tray application that watches your NVIDIA App / GeForce Experience
recordings folder and serves completed `.mp4` clips to a phone over the local Wi-Fi network.
A future iOS app will pair with this desktop app by scanning a QR code and download original,
byte-for-byte recordings.

> This is an unofficial hobby project and is not affiliated with, endorsed by, or connected
> to NVIDIA Corporation. "ShadowPlay" is a temporary working title. No NVIDIA assets are used.
>
> **Status:** Windows desktop app (MVP) implemented, plus a minimal SwiftUI iOS client
> under `ios/`. See **[docs/IOS_HANDOFF.md](docs/IOS_HANDOFF.md)** for the full contract.
>
> **CI:** every push/PR builds both artifacts on GitHub Actions —
> Windows exe (`ShadowPlay-win-x64`) and unsigned iOS IPA (`ShadowPlay-ios-unsigned-ipa`)
> via a macOS runner.

---

## What this MVP does

- Watches a folder you choose (recursively) for completed `.mp4` recordings.
- Runs quietly in the system tray after first-run setup; only **Exit** terminates it.
- Detects new recordings reliably: a clip is published only after its size and last-write
  time stay unchanged across multiple checks spanning several seconds, and only if the file
  can actually be opened for reading. Partially written files are never exposed.
- Hosts a small versioned HTTP API on your LAN (`/api/v1/...`) with clip listing and
  resumable, streamed downloads.
- Pairs phones via a one-time QR pairing code; paired devices authenticate with bearer
  tokens (only token *hashes* are stored) and can be revoked at any time.
- **Never** uploads, edits, deletes, re-encodes, or moves your recordings. It only reads them.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  ShadowPlay.Windows (WPF, net8.0-windows)                        │
│  • Tray icon (WinForms NotifyIcon), setup + main windows         │
│  • AppController: starts/stops sharing, owns pairing offers      │
│  • Generic Host + Microsoft.Extensions.DependencyInjection       │
└───────────────┬──────────────────────────────────┬───────────────┘
                │                                  │
┌───────────────▼───────────────┐   ┌──────────────▼───────────────┐
│  ShadowPlay.Api (net8.0)      │   │  ShadowPlay.Core (net8.0)    │
│  • Minimal APIs on Kestrel    │   │  • Clip monitor (FSW + polls │
│  • Bearer-token auth          │◄──┤    + reconciliation)          │
│  • Private-network guard      │   │  • Pairing & device registry │
│  • Range-enabled file results │   │  • Settings store, IDs, QR   │
└───────────────────────────────┘   └──────────────────────────────┘
                ▲
                │ tested by
     ┌──────────┴──────────┐
     │  ShadowPlay.Tests   │   xUnit; temp folders + fake clocks;
     │  (85 tests)         │   real Kestrel on port 0 for API tests
     └─────────────────────┘
```

Key decisions:

- **Clip IDs** are SHA-256 of the case-normalized full path: stable across restarts, opaque,
  and the API accepts nothing else (path traversal is structurally impossible).
- **Detection pipeline**: `FileSystemWatcher` events → per-path debounce → stability tracker
  (≥2 identical observations spanning ≥5 s) → read-probe → catalog. A periodic full scan
  reconciles the in-memory catalog so missed watcher events self-heal.
- **The API layer is transport-agnostic** (`LanApiFactory`): swapping plain HTTP for pinned
  local HTTPS later touches one file, not endpoint logic.
- **Settings** live under `%LocalAppData%\ShadowPlay\settings.json` (atomic writes);
  logs under `%LocalAppData%\ShadowPlay\logs` (rotating, size-capped).

## Requirements

- Windows 10/11 x64
- .NET SDK **8.0** (LTS) to build — see `global.json`
- To *run* the published app: [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0)
  **and** the ASP.NET Core 8 Runtime
- No NVIDIA software is required to build or test

## Restore, build, test, run

```powershell
# restore
dotnet restore ShadowPlay.sln

# build (Debug or Release)
dotnet build ShadowPlay.sln -c Release

# run all automated tests
dotnet test ShadowPlay.sln -c Release

# format check
dotnet format ShadowPlay.sln --verify-no-changes
```

Run from source:

```powershell
dotnet run --project src/ShadowPlay.Windows -c Release
```

First launch shows the setup window: pick your recordings folder, validate, done. The app
then lives in the tray (purple icon). Tray menu: **Open**, **Start/Pause sharing**,
**Open recordings folder**, **Settings**, **Exit**. Closing the window hides it to the tray.

### Selecting a test recordings folder

Any normal folder works — no NVIDIA software needed:

```powershell
mkdir C:\temp\fake-clips
# drop any .mp4 files in there (subfolders are scanned too)
dotnet run --project src/ShadowPlay.Windows -c Release   # choose C:\temp\fake-clips in setup
```

For an unattended headless check (no UI):

```powershell
publish\ShadowPlay.exe --smoke --folder C:\temp\fake-clips --port 0 --smoke-seconds 12
# prints SMOKE_OK {port} once healthy, then SMOKE_CLIPS {count}
```

Note: newly added files appear after ~6–9 seconds (stability window), by design.

## Local API summary (`http://<pc-ip>:5177/api/v1`)

| Endpoint | Auth | Description |
|---|---|---|
| `GET /health` | none | Liveness + server id (used pre-pairing) |
| `POST /pair/exchange` | pairing code | Swap a one-time code for a bearer token |
| `GET /server` | bearer | Server identity + clip count |
| `GET /clips` | bearer | Clip metadata, newest first |
| `GET /clips/{id}` | bearer | Single clip metadata |
| `GET /clips/{id}/download` | bearer | Streamed `video/mp4`, supports `Range` |

Errors: `400` malformed request, `401` missing/bad token, `403` non-private client IP,
`404` unknown id/route, `409` invalid/expired/reused pairing code, `500` unexpected.

### Pairing flow example

Scan the QR code shown in the desktop app. It encodes:

```json
{
  "v": 1,
  "serverId": "b0c1...",
  "computerName": "GAMING-PC",
  "lanAddress": "192.168.1.20",
  "port": 5177,
  "pairingCode": "7K2M-9QX4"
}
```

Exchange the code (must be within 10 minutes of generation, single-use):

```bash
curl http://192.168.1.20:5177/api/v1/pair/exchange \
  -H "Content-Type: application/json" \
  -d '{"pairingCode":"7K2M-9QX4","deviceName":"My iPhone"}'
```

```json
{
  "token": "k3Xc…(base64url, shown once)",
  "deviceId": "f2a9…",
  "server": { "serverId": "b0c1…", "computerName": "GAMING-PC", "protocolVersion": 1 }
}
```

### Authenticated requests

```bash
TOKEN="paste-token-here"

curl -H "Authorization: Bearer $TOKEN" http://192.168.1.20:5177/api/v1/clips

curl -H "Authorization: Bearer $TOKEN" \
     -o clip.mp4 http://192.168.1.20:5177/api/v1/clips/<id>/download

# resume an interrupted download
curl -H "Authorization: Bearer $TOKEN" -H "Range: bytes=1048576-" \
     -o rest.mp4 http://192.168.1.20:5177/api/v1/clips/<id>/download
```

Clip metadata shape (no paths are ever exposed):

```json
{ "id": "3F2A…64 hex chars", "fileName": "Valorant_2026-08-24.mp4",
  "sizeBytes": 482110412, "lastWriteTimeUtc": "2026-08-24T18:22:31Z" }
```

## Security model & limitations — read this

This MVP runs **plain HTTP on your LAN**:

- ✅ Devices are **authenticated**: clip endpoints require a valid bearer token issued
  through one-time pairing codes. Tokens are stored hashed (SHA-256); revocation works.
- ❌ Traffic is **NOT encrypted**. Anything on the same network segment can observe clip
  bytes, tokens, and metadata in transit. Do not use on untrusted Wi-Fi.
- ✅ Access is restricted to loopback/private addresses (RFC1918 + link-local); internet-
  routable clients get `403`.
- ⚠️ The pairing QR contains everything a phone needs; treat it like a password while visible.
- The app makes **no firewall changes** itself; Windows may ask you to allow listening on
  private networks on first run — allow it for the app only.

Planned hardening (architecture already supports it): pinned self-signed HTTPS between the
desktop app and the phone, replacing the plain transport in `LanApiFactory`.

## Publishing a win-x64 build

Framework-dependent (small; requires .NET 8 runtimes installed on target):

```powershell
dotnet publish src/ShadowPlay.Windows -c Release -r win-x64 --self-contained false -o publish
publish\ShadowPlay.exe
```

Fully self-contained single-file alternative:

```powershell
dotnet publish src/ShadowPlay.Windows -c Release -r win-x64 --self-contained true ^
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish-single
```

## Data locations

| What | Where |
|---|---|
| Settings + device registry | `%LocalAppData%\ShadowPlay\settings.json` |
| Logs (rotating, ≤512 KB × 4) | `%LocalAppData%\ShadowPlay\logs\shadowplay.log` |
| Recordings | untouched, wherever you pointed the app |

## Out of scope (for now)

- The iOS app itself
- Cloud storage, accounts, telemetry, external servers — there are none
- Automatic uploading/syncing, video editing, re-encoding, thumbnails
- Other recording providers (OBS, console capture, …)
- Installer / Microsoft Store packaging
- Automatic firewall changes, launch-at-startup
- HTTPS transport (structured for, not yet implemented)

## Repository layout

```
ShadowPlay.sln
src/
  ShadowPlay.Windows/   WPF app, tray, settings dialog, controller, DI composition, smoke mode
  ShadowPlay.Api/       LAN minimal API (auth, ranges, private-net guard)
  ShadowPlay.Core/      Monitoring, pairing, devices, settings (UI-free, testable)
tests/
  ShadowPlay.Tests/     xUnit suite (folder validation, completion detection, debouncing,
                        reconciliation, stable ids, traversal, pairing expiry/single-use,
                        token validation/revocation, API auth/listing/range downloads,
                        graceful shutdown)
ios/
  project.yml           XcodeGen spec (the .xcodeproj is generated, not committed)
  ShadowPlay/           Minimal SwiftUI client: QR pairing (+ manual entry), clip list,
                        AVPlayer streaming with token headers, chunked downloads
.github/workflows/
  build.yml             Builds Windows exe + unsigned iOS IPA on push/PR
```

## Building the iOS app locally

Requires a Mac with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd ios
xcodegen generate          # creates ShadowPlay.xcodeproj (git-ignored)
open ShadowPlay.xcodeproj
# Run on the Simulator: manual pairing mode works there (no camera needed)
```

> CI pins XcodeGen to **2.45.0** and selects `latest-stable` Xcode explicitly, because
> newer generators emit a project file format (`objectVersion 77`) that older Xcodes
> refuse to open. Locally, use any recent XcodeGen + Xcode 15/16 combination.

The CI-produced IPA is **unsigned**: sideload it with AltStore/Sideloadly or open the
project in Xcode and sign with your own Apple ID for device installs.
