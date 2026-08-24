# ShadowPlay — iOS Client Handoff

**Audience:** whoever builds the iPhone/iPad app (human or agent).
**Status of this doc:** describes the shipped Windows desktop MVP exactly as implemented
(verified against source and the automated test suite). Nothing here is aspirational
except the clearly-marked *Roadmap* items.

---

## 1. What exists today

A Windows tray application ("the desktop app") that:

- watches a user-chosen recordings folder recursively,
- publishes **completed** `.mp4` clips to an in-memory catalog (~6–9 s after a file stops
  changing; partial/temp files are never exposed),
- hosts a **plain-HTTP** REST API on the LAN, default port `5177`,
- pairs phones via one-time QR codes and authenticates them with bearer tokens,
- streams original recordings byte-for-byte with HTTP range/resume support.

It never modifies recordings. There are no cloud services, accounts, or telemetry.

**Your job:** build the iOS client that pairs with it over Wi-Fi and lets the user browse,
stream, and download those clips.

> **Update:** a minimal SwiftUI reference client now lives in `ios/` (XcodeGen project —
> run `xcodegen generate` inside `ios/`). It implements everything in this document:
> QR scanning + manual pairing, Keychain token storage, polling clip list,
> `AVPlayer` streaming with the bearer token injected via `AVURLAssetHTTPHeaderFieldsKey`,
> and chunked downloads to Documents. Use it as a starting point or as behavioral
> documentation; CI builds an unsigned IPA on every push.

## 2. Getting a test host running

You need a Windows machine (or VM) with .NET 8 Desktop Runtime + ASP.NET Core Runtime.

```powershell
git clone <this-repo> && cd ShadowPlay
dotnet build ShadowPlay.sln -c Release
dotnet run --project src/ShadowPlay.Windows -c Release      # UI mode: choose any folder with .mp4 files

# Headless (great for automated testing against a folder of dummy mp4s):
mkdir C:\temp\clips   # drop some .mp4 files here (subfolders OK)
publish\ShadowPlay.exe --smoke --folder C:\temp\clips --port 5177 --smoke-seconds 300
# prints: SMOKE_OK {"port":5177,"clipsAtReady":0}  … then stays up 300 s
```

Notes:

- New/staged clips appear **~6–9 s** after they stop changing (stability window). Bake
  retries/delays into tests.
- `--smoke` runs the identical pipeline and API as the UI, minus WPF.
- The executable contract for every behavior below lives in
  `tests/ShadowPlay.Tests/LanApiTests.cs` — read that file if anything seems ambiguous;
  it is the ground truth.

## 3. Identity model (important)

| Concept | Lifetime | Notes |
|---|---|---|
| `serverId` | permanent per Windows install | UUID hex, stored in settings.json. Use it as the stable identity of a PC. |
| LAN IP | changes (DHCP) | Never persist it long-term. Re-pair/re-discover when it changes. |
| Port | persistent (default `5177`) | User-editable in `%LocalAppData%\ShadowPlay\settings.json`. |
| Pairing code | 10 min, single use | Regenerating on the desktop invalidates the previous code immediately. |
| Bearer token | forever (until revoked) | Shown **exactly once** in the exchange response. Store it in the Keychain immediately. |
| `deviceId` | per paired device | Sent back at pairing; useful for "this device" labels. |

## 4. Pairing

### 4.1 The QR payload

The desktop main window shows a QR encoding this exact JSON (camelCase):

```json
{
  "v": 1,
  "serverId": "b0c1d2e3f4a5…32hex",
  "computerName": "GAMING-PC",
  "lanAddress": "192.168.1.20",
  "port": 5177,
  "pairingCode": "7K2M-9QX4"
}
```

Rules for your scanner:

- Accept only `"v": 1`. Show a clean "please update either app" error otherwise.
- Code format is visually `XXXX-XXXX` from the Crockford-base32 alphabet
  (no `I L O U`). You do **not** need to validate it client-side.
- Base URL = `http://<lanAddress>:<port>`.

### 4.2 Exchange endpoint

```
POST /api/v1/pair/exchange        (anonymous; also exempt from bearer auth)
Content-Type: application/json

{ "pairingCode": "7K2M-9QX4", "deviceName": "Alex's iPhone" }
```

- `deviceName` optional; trimmed, truncated to 64 chars server-side; defaults to
  `"Unnamed device"`.
- Response is **always delayed by ~300 ms** (anti-brute-force). Don't treat slowness as failure.

Success `200`:

```json
{
  "token": "k3Xc9m2_pQ…43ish chars, base64url, no padding",
  "deviceId": "8f14e45fceea167a5a36dedd4bea2543",
  "server": {
    "serverId": "b0c1d2e3f4a5…",
    "computerName": "GAMING-PC",
    "protocolVersion": 1,
    "startedUtc": "2026-08-24T09:15:00Z",
    "clipCount": 42
  }
}
```

Failure `409`:

```json
{ "error": "pairing_code_invalid_or_expired" }
```

Malformed body `400`: `{ "error": "invalid_request" }`.

Semantics you must handle:

- Unknown code, expired (>10 min), and already-used codes all return the **same** 409 —
  deliberately indistinguishable. UX: show "Code invalid or already used — generate a new
  one on the PC."
- Codes are single-use. If your app crashes between receiving the token and persisting it,
  the code is burned: ask the user to show a fresh QR (`New pairing code` button).
- Before exchanging, you may verify you're talking to the right machine:
  `GET /api/v1/health` (anonymous) returns `{ "status":"ok", "serverId":"…" }` — compare
  `serverId` with the QR payload.

## 5. API reference (all under `/api/v1`)

All authenticated calls require:

```
Authorization: Bearer <token>
```

Missing/bad/revoked token → `401` + header `WWW-Authenticate: Bearer` +
body `{ "error": "unauthorized" }`.

### GET /health — anonymous

```json
{ "status": "ok", "serverId": "…", "protocolVersion": 1, "timeUtc": "2026-08-24T09:15:00Z" }
```

Use for reachability checks and server-id confirmation.

### GET /server — auth

Same shape as `server` object above (identity + current clip count).

### GET /clips — auth

Returns a JSON array, **newest first**, of zero or more:

```json
{
  "id": "3F2AB64C…64 uppercase hex chars",
  "fileName": "Valorant_2026-08-24_18-22.mp4",
  "sizeBytes": 482110412,
  "lastWriteTimeUtc": "2026-08-24T18:22:31Z"
}
```

Guarantees:

- `id` matches `^[0-9A-F]{64}$`. Treat it as opaque; never parse it.
- No filesystem paths appear anywhere in API responses (enforced by tests).
- Order: `lastWriteTimeUtc` descending. There is **no pagination** in v1 — fine for
  realistic library sizes (< a few thousand).

### GET /clips/{id} — auth

Single clip, same shape, or `404 { "error": "clip_not_found" }`.

Any id that isn't 64 hex chars also returns 404 (never 400) — path-traversal attempts are
structurally impossible because ids are looked up in a fixed catalog.

### GET /clips/{id}/download — auth

Streams the file from disk:

- `200 OK`, `Content-Type: video/mp4`,
- `Accept-Ranges: bytes`, `ETag`, `Last-Modified` present,
- `Content-Disposition: attachment; filename*=utf-8''<safe name>` — name derived from the
  recording (sanitized); use it for "Save to Files".
- Supports `Range: bytes=a-b`, open-ended `bytes=a-`, suffix `bytes=-n`; answers
  `206 Partial Content` with `Content-Range`, honors `If-Range`, and returns
  `416 Requested Range Not Satisfiable` for out-of-bounds ranges.
- If the file vanished after listing (user deleted/moved it), you get
  `404 { "error": "clip_no_longer_available" }` — handle mid-download failures gracefully.

### Error summary

| Status | Meaning | Body |
|---|---|---|
| 400 | malformed pair request | `{"error":"invalid_request"}` |
| 401 | missing/invalid/revoked bearer token | `{"error":"unauthorized"}` |
| 403 | your IP is not loopback/private (different network / VPN) | `{"error":"forbidden"}` |
| 404 | unknown route/id, or clip file gone | `{"error":"clip_not_found"}` or `"clip_no_longer_available"` |
| 409 | pairing code unknown/expired/reused | `{"error":"pairing_code_invalid_or_expired"}` |
| 500 | unexpected server error | `{"error":"internal_error"}` |

## 6. Behavior notes & gotchas

- **No push, no websockets.** Poll `/clips` (e.g., every 10–30 s while the list is on
  screen, plus pull-to-refresh).
- **IP churn:** if downloads start failing with connection errors, the PC's IP probably
  changed. Re-show pairing/discovery; match by `serverId` so saved devices reconnect
  without re-pairing once the new address is found.
- **Revocation:** if the user hits Revoke on the PC, your stored token dies instantly
  (401s). Route 401 → "This PC revoked access — pair again" flow, then delete the Keychain item.
- **Multiple PCs:** supported naturally — key all persistence by `serverId`.
- **Downloads vs streaming:** `AVPlayer` can play the download URL directly (ranges are
  supported). For offline saving prefer `URLSession.downloadTask` — resume after
  interruption works out of the box thanks to range support.

## 7. iOS-specific requirements checklist

- [ ] **ATS**: connections are plain `http://` to LAN IPs → set
      `NSAppTransportSecurity → NSAllowsLocalNetworking = YES` in Info.plist.
- [ ] **Local network privacy prompt** (iOS 14+): add
      `NSLocalNetworkUsageDescription` explaining why ("Find and talk to ShadowPlay on
      your home network").
- [ ] **Keychain** for tokens (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
      keyed by `serverId`.
- [ ] **Background**: no background execution guarantees; design around short sessions.
- [ ] Do not ship a universal "allow arbitrary loads" exception; keep it local-network scoped.

## 8. Suggested starting architecture (SwiftUI)

```swift
// Models — wire-exact (camelCase via default JSONDecoder with .iso8601 dates)
struct QrPayload: Codable { let v: Int; let serverId, computerName, lanAddress: String
                            let port: Int; let pairingCode: String }
struct Clip:    Codable { let id, fileName: String; let sizeBytes: Int64
                            let lastWriteTimeUtc: Date }
struct PairResponse: Codable { let token, deviceId: String; let server: ServerInfo }
struct ServerInfo:   Codable { let serverId, computerName: String
                                let protocolVersion: Int; let startedUtc: Date
                                let clipCount: Int }

enum Endpoint {
    static func base(_ p: QrPayload) -> URL {
        URL(string: "http://\(p.lanAddress):\(p.port)/api/v1")!
    }
}
```

Screens:

1. **Pairing** — `DataScannerViewController`/`AVMetadataMachineReadableCodeObject`
   scanning `.qr`, decode `QrPayload`, reject `v != 1`, confirm PC name, call exchange,
   store token.
2. **Library** — list of `Clip` (name, size, date), pull-to-refresh + timer poll,
   tap → player sheet; swipe/download button → `URLSession` download with progress.
3. **Settings** — connected PCs (by `serverId`), "forget" (= delete local token; revoking
   must be done on the PC), re-pair buttons.

## 9. Security posture (be honest in UI copy)

- Traffic is **HTTP, not encrypted**. Authentication ≠ confidentiality: anyone on the same
  Wi-Fi can observe traffic. Copy suggestion: *"Works best on your trusted home Wi-Fi."*
- Roadmap (desktop side is structured for it): self-signed certificate generated by the
  desktop app, embedded in the QR payload, pinned by the app, transport swapped inside
  `LanApiFactory` (one file) without touching endpoints. When that lands, drop the ATS
  exception and this section.

## 10. Where things live in this repo

| Path | What it is |
|---|---|
| `src/ShadowPlay.Api/LanApiFactory.cs` | Transport/host composition (future HTTPS swap point) |
| `src/ShadowPlay.Api/Endpoints/LanApiEndpoints.cs` | Every route, verbatim |
| `src/ShadowPlay.Core/Networking/QrPayload.cs` | QR schema, versioned |
| `src/ShadowPlay.Core/Pairing/*` | Code lifetime/single-use rules |
| `tests/ShadowPlay.Tests/LanApiTests.cs` | Executable API contract (85 tests total) |
| `README.md` | Desktop-side docs, publish instructions |

## 11. Open decisions for the iOS team

- Manual-code-entry fallback (typing the 8-char code + IP) or QR-only?
- Discover unpaired PCs via Bonjour later? (Desktop currently doesn't advertise — would
  need a small desktop addition; polling known hosts is fine for v1.)
- Thumbnail strategy is explicitly out of scope until the desktop side opts into
  generating them.
