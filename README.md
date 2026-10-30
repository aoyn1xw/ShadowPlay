# ShadowPlay (working title)

A lightweight Windows tray application that watches your NVIDIA App / GeForce Experience
recordings folder and serves completed `.mp4` clips to your phone over the local Wi-Fi network.
A cross-platform Flutter mobile app (Android & iOS) pairs with this desktop app by scanning a QR code and downloads original,
byte-for-byte recordings.

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/aoyn1xw/ShadowPlay)

> This is an unofficial hobby project and is not affiliated with, endorsed by, or connected
> to NVIDIA Corporation. "ShadowPlay" is a temporary working title. No NVIDIA assets are used.
>
> **Status:** Windows desktop app (MVP) implemented, plus a cross-platform Flutter mobile client
> under [`flutter/`](flutter/README.md).
>
> **CI:** pull requests run Windows, Flutter, Android, and unsigned iOS checks. Successful `main`
> builds refresh the `latest` prerelease, while version tags (`v*`) publish normal Windows and
> Android releases. Signed iOS OTA builds run separately from [`ios-ota.yml`](.github/workflows/ios-ota.yml).

---

## What this MVP does

- Watches a folder you choose (recursively) for completed `.mp4` recordings.
- Runs quietly in the system tray after first-run setup; only **Exit** terminates it.
- Detects new recordings reliably: a clip is published only after its size and last-write
  time stay unchanged across multiple checks spanning several seconds, and only if the file
  can actually be opened for reading. Partially written files are never exposed.
- Hosts a small versioned LAN API (`/api/v1/...`) with clip listing and resumable, streamed
  downloads. Phones paired via a v2 QR code use the **certificate-pinned HTTPS** listener
  (`https://<pc-ip>:<httpsPort>`); there is no silent HTTP/HTTPS downgrade.
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
- To build the Flutter mobile client: Flutter **3.47.2** and Java **17**
- Android builds require Android SDK platform **37.0** because
  `flutter_secure_storage` **11.0.0** requires compilation against Android API 37.
  This does not change the app's minimum or target Android SDK settings.

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

## Local API summary (`http://<pc-ip>:5177/api/v1`; TLS: `https://<pc-ip>:<httpsPort>/api/v1`)

| Endpoint | Auth | Description |
|---|---|---|
| `GET /health` | none | Liveness + server id (used pre-pairing) |
| `POST /pair/exchange` | pairing code | Swap a one-time code for a bearer token |
| `GET /server` | bearer | Server identity + clip count |
| `GET /clips` | bearer | Clip metadata, newest first |
| `GET /clips/{id}` | bearer | Single clip metadata |
| `GET /clips/{id}/download` | bearer | Streamed `video/mp4`, supports `Range` |
| `GET /clips/{id}/thumbnail` | bearer | Authenticated JPEG preview when available |

Errors: `400` malformed request, `401` missing/bad token, `403` non-private client IP,
`404` unknown id/route, `409` invalid/expired/reused pairing code, `500` unexpected.

### Pairing flow example

Scan the QR code shown in the desktop app. It encodes:

```json
{
  "v": 2,
  "serverId": "b0c1...",
  "computerName": "GAMING-PC",
  "lanAddress": "192.168.1.20",
  "port": 5177,
  "pairingCode": "7K2M-9QX4",
  "httpsPort": 5178,
  "certSha256": "A1B2... 64 hex characters (SHA-256 of the TLS leaf certificate)"
}
```

Protocol version 2 adds the pinned-TLS fields `httpsPort`/`certSha256`; phones that scan them
pin the certificate at pairing time. If the certificate could not be created on this PC (for
example a store failure), the QR is emitted without these fields and phones keep using plain
HTTP - never a silent fallback after pairing.

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
  "server": { "serverId": "b0c1…", "computerName": "GAMING-PC", "protocolVersion": 2,
    "serverVersion": "0.1.0", "apiVersion": 1,
    "capabilities": ["clips.rangePlayback", "clips.duration", "clips.thumbnails"],
    "httpsPort": 5178, "httpsCertSha256": "A1B2..." }
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

Phones that paired with a v2 QR use the pinned TLS listener instead; the same bearer token is
accepted on both transports because authentication is connection-based:

```bash
# HTTPS with the certificate the phone pinned at pairing time
curl --cacert shadowplay.pem -H "Authorization: Bearer $TOKEN" \
     -o clip.mp4 https://192.168.1.20:5178/api/v1/clips/<id>/download
```

`httpsPort`/`httpsCertSha256` are advertised by `/api/v1/server` (and in the QR), and the HTTP
fields are simply absent for servers that could not start TLS. Video previews against the TLS
listener are a limitation: the platform media player on the phone cannot install the pin, so
in-app playback streams only from a previously downloaded local copy, while downloads with
resume work over HTTPS like any other request.

Clip metadata shape (no paths are ever exposed):
```json
{ "id": "3F2A…64 hex chars", "fileName": "Valorant_2026-08-24.mp4",
  "sizeBytes": 482110412, "lastWriteTimeUtc": "2026-08-24T18:22:31Z",
  "durationMilliseconds": 18400,
  "thumbnailUrl": "/api/v1/clips/<id>/thumbnail" }
```

The `lastWriteTimeUtc` field is the recording timestamp used by the desktop
monitor. `durationMilliseconds` and `thumbnailUrl` are optional for older or
unsupported media. The thumbnail endpoint is authenticated like the download
endpoint. Clients can play directly from `/clips/<id>/download`; the existing
HTTP Range support lets compatible players request only the needed bytes.

## Security model & limitations — read this

This MVP keeps **plain HTTP as the legacy transport** for phones paired before pinned TLS
shipped, and runs a **certificate-pinned HTTPS listener alongside it** for phones that pair
via a v2 QR:

- The desktop app generates (once) and reuses a self-signed **ECDSA P-256** certificate in the
  current user's certificate store (`CN=ShadowPlay Local`), covering every current LAN address.
  Phones pin its **SHA-256 fingerprint** from the QR at pairing time; later connections only
  succeed when the presented certificate matches (or they fail to connect, with no silent
  fallback to HTTP).
- A regenerated certificate (new LAN addresses beyond its SANs, or expiry) intentionally breaks
  existing TLS pairings: phones must re-scan the QR, which is exactly how a machine-in-the-middle
  would be detected instead of being silently accepted.
- Phones already paired with a v1 QR keep plain HTTP and are upgraded only by re-pairing.

On the legacy plain HTTP transport (still enabled for the bootstrap/legacy path):

- ✅ Devices are **authenticated**: clip endpoints require a valid bearer token issued
  through one-time pairing codes. Tokens are stored hashed (SHA-256); revocation works.
- ❌ Traffic is **NOT encrypted**. Anything on the same network segment can observe clip
  bytes, tokens, and metadata in transit. Do not use on untrusted Wi-Fi.
- ✅ Access is restricted to loopback/private addresses (RFC1918 + link-local); internet-
  routable clients get `403`.
- ⚠️ The pairing QR contains everything a phone needs; treat it like a password while visible.
- The app checks for **narrow inbound TCP rules** for the running executable and every listener
  port (HTTP and HTTPS). From the main window, **Allow private LAN access** can create/update
  those rules after an administrator confirmation, and the update also deletes the legacy
  single-port rule so no stale port stays open. The rules are limited to the Private profile;
  ShadowPlay never disables Windows Firewall or opens the Public profile. Mark the active
  Wi-Fi network Private in Windows before pairing. A firewall rule for an older copy of
  `ShadowPlay.exe` does not authorize a new install path.

Pinned HTTPS is implemented (see above): dual HTTP+TLS listeners in `LanApiFactory`, a QR v2
payload carrying `httpsPort`/`certSha256`, and per-port private-profile firewall rules.

## Building the Windows installer

The installer contains the self-contained Windows x64 publish, so the target computer does not
need a separate .NET runtime. Install Inno Setup 6, choose a release version, then run these
commands from the repository root:

```powershell
dotnet restore src/ShadowPlay.Windows/ShadowPlay.Windows.csproj -r win-x64
$version = "0.1.0"
dotnet publish src/ShadowPlay.Windows/ShadowPlay.Windows.csproj `
  -c Release -r win-x64 --self-contained true --no-restore `
  -p:Version=$version -o publish/win-x64
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
& $iscc "/DMyAppVersion=$version" installer\ShadowPlay.iss
```

The finished installer is `artifacts\installer\ShadowPlay-Setup-0.1.0.exe`. It installs per
machine into `C:\Program Files\ShadowPlay`, creates a Start Menu shortcut, offers an optional
desktop shortcut, and registers its uninstaller with Windows. Reinstalling with the same stable
installer identity upgrades the existing installation. Uninstall preserves `%LocalAppData%\ShadowPlay`
unless the user explicitly chooses to remove settings, pairing information, logs, and cached
previews.

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

## GitHub Actions

The workflows are separated by purpose:

- [`ci.yml`](.github/workflows/ci.yml) runs on pull requests and manual dispatch. It owns the
  Windows build/test/smoke check, shared Flutter dependency/analyze/test validation, Android
  debug compilation, and unsigned iOS compilation. The Android job installs platform 37.0
  before compiling. PR CI does not use iOS signing secrets.
- [`release.yml`](.github/workflows/release.yml) runs on `main`, version tags matching `v*`, and
  manual dispatch. It builds the Windows x64 Inno Setup installer and Android release APK. A
  successful `main` build refreshes the `latest` prerelease while preserving its signed iOS IPA;
  version tags create or update normal GitHub Releases.
- [`ios-ota.yml`](.github/workflows/ios-ota.yml) runs through manual dispatch, keeping signed
  builds out of ordinary `main` pushes. It owns certificate/profile installation, signed iOS OTA
  export, the `latest` OTA release, and the OTA manifest.
- [`codeql.yml`](.github/workflows/codeql.yml) remains a separate CodeQL analysis workflow.

CI keeps the normal debug and unsigned build outputs inside their jobs rather than uploading them
as routine artifacts. The Android release job currently uses the existing project signing
configuration; configure a release keystore separately before treating that APK as store-ready.

## Data locations

| What | Where |
|---|---|
| Settings + device registry | `%LocalAppData%\ShadowPlay\settings.json` |
| Logs (rotating, ≤512 KB × 4) | `%LocalAppData%\ShadowPlay\logs\shadowplay.log` |
| Recordings | untouched, wherever you pointed the app |
| Mobile diagnostics logs (rotating, ≤10 MB total across 2 files) | App documents `diagnostics/` folder (`flutter/` client; see [Mobile diagnostics](#mobile-diagnostics--troubleshooting)) |
| iOS high-frame-rate Photos export notes (DEBUG builds) | App documents `ShadowPlayDiagnostics/` folder |

## Out of scope (for now)

- Cloud storage, accounts, telemetry, external servers — there are none
- Automatic uploading/syncing, video editing, or re-encoding
- Other recording providers (OBS, console capture, …)
- Microsoft Store packaging
- Launch-at-startup

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
                        pinned HTTPS end-to-end, QR payload contract, firewall rule script)
flutter/
  lib/                  Cross-platform mobile client (Home, Clips, Player, Settings, Diagnostics, Onboarding)
  test/                 Unit and widget test suites
.github/workflows/
  ci.yml                Pull-request validation and manual checks
  release.yml           Rolling latest and versioned Windows/Android releases
  ios-ota.yml           Signed iOS OTA build and distribution
  codeql.yml            Separate CodeQL analysis
```

## Cross-platform mobile client

The Flutter client lives in [`flutter/`](flutter/README.md). It is the
cross-platform mobile client for Android and iOS: pair over LAN via QR or manual entry,
browse available clips, download recordings with parallel transfers, and play the local copies offline.

## Mobile diagnostics & troubleshooting

The mobile client keeps a private, structured local log (JSON Lines) in
[`flutter/lib/core/diagnostics.dart`](flutter/lib/core/diagnostics.dart).
Nothing is uploaded: entries stay on the device until you share an exported report.

**What is recorded** — app lifecycle (start/restore, app resume/pause in verbose mode),
pairing (preflight, QR errors, PC paired/forgotten, certificate-pin mismatch — the pin
itself is never logged), network (refresh success/failure, PC reachability), downloads
(start/finish/cancel/failure plus progress at 25% checkpoints, not per chunk), playback
(opened/failed/closed) and Photos/Gallery saves. Each entry has a UTC timestamp,
severity (`debug`/`info`/`warn`/`error`) and a component name (`app`, `pairing`,
`network`, `download`, `playback`, `gallery`, `library`, `diagnostics`).

**Normal vs verbose mode** — normal mode records info/warn/error. The *Verbose
diagnostics* switch in `Settings → Diagnostics` also records `debug` events
(progress checkpoints, lifecycle transitions, PC reachability) and keeps that
setting across restarts.

**Redaction guarantees** — applied before anything is stored: bearer tokens,
authorization/proxy-authorization header values, pairing codes in key=value form,
access/api/session/device token values in key=value form, PEM private key /
certificate blocks, and private filesystem paths (Windows and POSIX) are replaced
with placeholders; only the file basename survives. Context values under sensitive
keys (token, pairing code, password, …) are dropped entirely.
`/api/v1/...` request paths are deliberately kept readable.

**File locations**

| Platform | Location |
|---|---|
| iOS | App-sandbox `Documents/diagnostics/` — visible only inside the app or via Xcode; the sandbox is not exposed through the Files app |
| Android | App-private storage — `/data/user/0/com.ayon1xw.shadowplay/app_flutter/diagnostics/` (needs `adb shell run-as` on debug builds) |

Two files rotate (`diagnostics.log`, `diagnostics.1.log`) under a 10 MB total
default (adjustable at attach time); when the current file reaches half the
budget it is renamed to the archive and the previous archive is deleted.

**In-app tools** (`Settings → Diagnostics`):

- *View recent events* — newest-first list; tap an entry for full details.
- *Export report* (share icon) — builds a text report (header with mode/storage,
  both files' newest content, and on iOS the newest
  `ShadowPlayDiagnostics/*.txt` high-frame-rate Photos-export notes) and opens
  the native share sheet. That share is the only way data leaves the device.
- *Clear logs* (trash icon) — deletes both files and the in-memory view;
  logging continues afterwards with a fresh file.
- If file storage is unavailable (rare), the app buffers in memory for the
  session and says so in the report header.

**Troubleshooting quick reference**

| Symptom | Where to look |
|---|---|
| Clip never appears | `network` events: refresh failures, then the `download` events for the transfer or error text |
| Downloads stall or break mid-file | `download` events: progress checkpoints stall at N% → server/PC side; repeated `Download failed` errors include the failure reason |
| Playback shows an error | `playback` `Player failed to initialize` events carry the player error |
| "Save to Photos" missing the clip | `gallery` events: permission denied vs save failed |
| Pairing loop | `pairing` events: preflight failures (address/port/transport), permission state, or a certificate-pin mismatch refusal |
| To hand logs to support | Settings → Diagnostics → export → share via email/ AirDrop/… ; attach the exported `.txt` |

