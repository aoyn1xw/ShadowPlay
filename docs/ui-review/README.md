# Flutter companion UI review — 2026-09-05

ShadowPlay's mobile job is to browse PC recordings, select and download originals,
watch local copies, and save them to the gallery. Home, Clips, Settings and the
existing QR/manual pairing flow remain in place.

## Research before implementation

Used the requested `ui-radar` skill and UIZZE's public catalogue. The initial
video-library search returned HBO Max screens; a focused downloads query returned
no results. Inspected the actual screenshots and retained two references:

| Reference | Visible observation | Applied decision |
| --- | --- | --- |
| [Media catalogue](https://uizze.com/screens/587e92df3bdf0f188b23d50e5e6d851d) | The My List section pairs landscape previews with titles outside the image. | Preserve 16:9 preview geometry and readable file information. Do not copy promotional rails, artwork, logo, or branding. |
| [Download settings](https://uizze.com/screens/edee6317122df37a0a2e3531fec30841) | Settings use labeled rows, trailing controls and dividers. | Use ordinary settings rows; retain actual storage bytes instead of inventing capacity percentages. Do not copy the blue accent or branded chart. |

Applied `ui-design`'s new-work playbook. Queried current Flutter documentation with
Context7 for Material 3 theming and text layout.

Used `design-mobile-apps` after user-approved Sleek sign-in and explicit approval
of the transmitted brief. [Sleek study](https://sleek.design/project/WfHOW5nay0s).
Fetched the active component HTML and individual, combined, and full-height
screenshots for all four generated screens. Adopted compact headings, neutral
surfaces, green action accents, and landscape media geometry. Excluded its
invented secondary tabs, notifications inbox, GPU details, bandwidth/cancel UI,
cellular preference, capacity chart, pairing instructions/port/PIN format and
version number. These are reference concepts, not authoritative product behavior.

## Implemented direction

- Neutral light and charcoal dark themes, restrained green for actions and selection.
- Flat media rows replace tall two-column cards. Filenames have two lines;
  file size and date have separate space. Real thumbnails and local video previews
  remain in use. Missing previews stay neutral.
- Separate play and selection controls, labeled gallery actions, per-recording
  progress/errors, and a full-width batch-download action above the existing tabs.
- At narrow widths or large text, media rows stack vertically; clip headers scroll
  with the library so landscape keeps usable content space.
- Settings retain all controls. Theme choice uses a native bottom sheet; forgetting
  a PC has an explicit unlink icon and still requires the existing confirmation.
- Onboarding uses concise permission explanations and scrollable layouts. QR/manual
  selection, camera permissions, health preflight and pairing methods are preserved.
- The player retains playback/seek/fullscreen behavior with a consistently dark,
  readable error surface, even when the rest of the app uses light mode.

## Anti-ui-slop finish gate

Applied the requested skill's audit playbook to source and actual Flutter renders.
Three material findings were corrected and checked again:

1. At 320×568 with 200% text, the first onboarding layout overflowed by 40 pixels.
   Replaced the intrinsic-height/flexible layout with a scrollable list.
2. Fixed clip headers left too little room for landscape with large text.
   Moved the header, library label and recordings into one sliver scroll view;
   the batch action stays reachable above navigation.
3. Player errors inherited light-theme text on black. Scoped the player to dark
   colors, explicitly themed its title, and allowed the error content to scroll.

Also separated the preview play target from its duration badge, removed the
duplicate placeholder icon beneath Play, corrected download-retry wording, and
kept gallery-failure feedback visible next to its retry control.

**Gate result:** no remaining material findings in the inspected UI and tested
states. No gradients, dashboard metrics, decorative animation, fabricated media,
new dependencies, or replacement services were introduced.

## Validation and limits

- Flutter 3.47.2 / Dart 3.13.2; dependency restore succeeded without lockfile changes.
- Dart formatting check and Flutter analysis pass.
- 32 tests pass, including existing pairing/API/gallery contracts and six new
  layout/recovery tests.
- Rendered actual widgets at 390×844 in light/dark mode; exercised 320×568 and
  844×390 at 200% text. Tested selection, disabled download controls, progress,
  errors, theme switching, local player navigation, offline recovery, loading,
  onboarding and manual-pairing field access.
- Core services/state/models, the navigation shell and dependency files have no diff.
- Android debug APK built successfully; Gradle reported existing mobile_scanner
  Kotlin-plugin and SDK-tool compatibility warnings.
- Screenshots use synthetic test filenames and neutral missing-media previews.
  They are widget renders, not physical-device captures. Camera scanning, LAN
  pairing, playback decoding and native Photos/Gallery export were not exercised
  against a real phone/PC in this session. iOS build requires macOS.

Local screenshots are in `flutter/` next to this document; Sleek reference HTML
and images are in `sleek/`. Both artifact directories are ignored by Git.

From the repository's `flutter/` directory, regenerate widget screenshots:

```powershell
flutter test --dart-define=UI_REVIEW=true --dart-define=UI_REVIEW_FONT=<Flutter SDK>/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf
```

Omit those defines for the normal test suite. The optional font file is loaded
only by the review harness; no font assets or sample data are added to the app.
