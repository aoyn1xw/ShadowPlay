# ShadowPlay design QA

## Visual truth and viewport

- Source of visual truth: `C:\Users\ayon1xw\.codex\attachments\3d251d4f-548c-4610-960a-0b722ebbe478\image-1.png` (1522 × 1033 px). It is a multi-screen structural wireframe, not a single pixel-perfect device viewport.
- Implementation viewport: Pixel 10 Android emulator at 1080 × 2424 physical px, 420 dpi (2.625 density), approximately 411.4 × 923.4 logical dp.
- Fullscreen player viewport: 2424 × 1080 physical px after landscape rotation.
- Same-input comparison boards:
  - `design-qa-artifacts/comparison-onboarding.png`
  - `design-qa-artifacts/comparison-main-flow.png`

## Captured states

- First-run intro, camera explanation, QR pairing, manual pairing, Android camera permission, and denied-permission fallback.
- Connected Home with a real local video preview and duration.
- Clips grid, one selected clip, singular download action, and two-selected plural semantics.
- Settings at the top and scrolled through storage, notifications, appearance, and About.
- Local player in portrait and fullscreen landscape.

## Review

### Layout, spacing, type, and color

The implementation preserves the wireframe hierarchy: first-run pairing precedes a three-destination shell; Home prioritizes the active PC and local clips; Clips uses a selectable grid and contextual download action; Settings groups devices and app preferences. Material 3 spacing, typography, radii, selected states, and the blue accent are internally consistent at the emulator viewport. No content is clipped, overlapped, or pushed beneath system navigation.

The wireframe is intentionally sparse. The implementation adds production detail without changing the information architecture: explicit online/offline status, sync timing, storage usage, download state, and light/dark/system appearance controls.

### Images and icons

Material icons are used consistently for navigation, pairing, device state, video placeholders, downloads, settings, and player controls. Downloaded local videos render an actual frame and duration. Remote clips use a neutral video poster because the current server DTO does not provide thumbnails or durations.

### Copy

Copy is concise and action-oriented. Singular and plural download labels are correct. Camera access is explained before the operating-system permission prompt, and denial exposes a manual fallback. Downloaded clips are described as local/offline playback rather than remote streaming.

### Interaction and accessibility

- Onboarding controls, QR/manual mode switching, manual fields, and the camera-permission sequence were exercised on the emulator.
- Home, Clips, and Settings preserve state through an `IndexedStack`.
- Clip selection was exercised for one and two clips; the action bar updated from `Download 1 clip` to `Download 2 clips`.
- Local playback, seek progress, and fullscreen landscape rotation were exercised with a five-second MP4.
- Android accessibility semantics expose tab position, selected tab, clip cards, selection count, download action, slider percentage, and fullscreen action.
- During QA, the player play/pause control was found to have no semantic label. A dynamic `Play`/`Pause` tooltip was added before the final validation run.
- Touch targets use standard Material controls and meet the expected mobile target size.

## Severity history

- P0: none.
- P1: none.
- P2: unlabeled play/pause control; fixed by adding a dynamic tooltip.
- Remaining actionable P0/P1/P2 issues: none.

final result: passed
