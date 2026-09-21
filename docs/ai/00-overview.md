# NoTeleCamera — agent context

> Generated from 5c01e70 (2026-09-17) by project-onboard.
> This is a cache of the codebase, not a specification. Verify anything load-bearing
> against the code before relying on it, and refresh with: "refresh docs/ai".

## What this is

A single-target SwiftUI/AVFoundation iPhone camera app for one physical device: an
iPhone 13 Pro whose **77 mm telephoto OIS is mechanically broken and rattles into video
audio**. The entire app exists to guarantee that lens is never powered: the rear camera is
locked to `builtInDualWideCamera` (0.5x ultra-wide + 1x wide) and slow-motion to
`builtInWideAngleCamera`. It replaces the stock Camera app with five modes
(time-lapse, slo-mo, video, photo, portrait), and talks to nothing off-device —
no network, no backend, no analytics. Its only external sinks are the Photos library,
Core Location and Core Motion.

## Project profile

| Field | Value |
|---|---|
| Language / stack | Swift 5.9, SwiftUI + AVFoundation, UIKit interop for preview & volume-button shutter |
| Platform | iOS 26.0+ (`project.yml:15,19`), portrait-only (`Info.plist` `UISupportedInterfaceOrientations`) |
| Project generation | XcodeGen from `project.yml` — **there is no committed `.xcodeproj`** |
| Package manager | none (no SPM/CocoaPods/Carthage manifests) |
| Build | `xcodegen generate` then `xcodebuild archive` — see `.github/workflows/build.yml` |
| Test command | none — repo has no test target and no test files |
| Lint / format | none configured |
| Migrations | n/a |
| Git host / CI | GitHub Actions on `macos-26`, unsigned archive only |
| Base branch | `main` |
| Signing | `DEVELOPMENT_TEAM: ""` (`project.yml:29`) — a real-device run needs a team set locally |

**Unknowns:** no way to build or type-check on the current host (Windows). The only static
check available here is `swiftc -frontend -parse`; everything semantic is CI- or Mac-only.

## Entry points

| Kind | Where | Notes |
|---|---|---|
| App | `App.swift:35` `@main struct NoTeleCameraApp` -> `ContentView()` | single `WindowGroup` |
| UI root | `CameraUI.swift:502` `ContentView` | owns the whole screen; drives `CameraManager` lifecycle from `scenePhase` (`CameraUI.swift:593`) |
| Camera core | `CameraManager.swift:42` `@MainActor final class CameraManager` | session graph, lens choice, zoom, focus, recording |
| Capture path | `CameraManagerCapture.swift` `extension CameraManager` | photo/ProRAW/Live Photo/portrait, plus all `AVCapturePhotoCaptureDelegate` callbacks |
| Post-processing | `MediaProcessing.swift:32` `enum MediaProcessing`, `:143` `TimeLapseRecorder` | slo-mo time stretch, time-lapse assembly, metadata-preserving crop |
| Hardware shutter | `CameraUI.swift:393` `VolumeShutter` | KVO on `AVAudioSession.outputVolume` |

## Module map

| Path | Responsibility | Depends on |
|---|---|---|
| `CaptureTypes.swift` | enums (mode, aspect, timer, quality, rate, interval, format), `ScannedCode`, `CameraSettings` + UserDefaults persistence | AVFoundation |
| `CameraManager.swift` | session graph, `bestDevice`, mode switching, zoom/focus/EV/torch, recording, time-lapse scheduling, interruption handling, level/motion | all of the below |
| `CameraManagerCapture.swift` | `capturePhoto`, pending-capture bookkeeping + watchdogs, `savePhoto`, `PortraitRenderer` | `CameraManager`, `MediaProcessing` |
| `MediaProcessing.swift` | `slowDown`, `cropPreservingMetadata`, `thumbnail`, `TimeLapseRecorder` | AVFoundation, ImageIO |
| `CameraUI.swift` | preview layer, overlays (focus/grid/level), mode selector, zoom pill, shutter gestures, scan banner, settings sheet | `CameraManager` |
| `App.swift` | `@main` | `CameraUI` |

## External dependencies

| Service | Used for | Where | Failure behaviour |
|---|---|---|---|
| Photos (PhotoKit) | the only persistence of output media | `CameraManager.swift:1617` `saveVideo`, `CameraManagerCapture.swift` `savePhoto` | sets `errorMessage`; **temp source file is deleted regardless** — see Gotchas |
| Core Location | GPS tag on saved assets | `CameraManager.swift` `currentLocation` | no age/accuracy validation; updates never stop on background |
| Core Motion | level indicator | `CameraManager.swift` `startMotion` | silently inert if unavailable |
| `photos-redirect://` URL scheme | thumbnail tap opens Photos | `CameraUI.swift:1278` | undocumented Apple scheme; App Review risk |

## Where new code goes

| Adding... | Goes in | Copy this reference |
|---|---|---|
| a user-facing setting | `CameraSettings` in `CaptureTypes.swift` (field + `Key` + `load()` + `save()`) **and** a row in `SettingsSheet` (`CameraUI.swift:1461`) | `portraitIntensity` |
| a capture mode behaviour | the `switch mode` inside `applyMode` (`CameraManager.swift:659`) | the `.slomo` branch |
| anything touching the session graph | a `sessionQueue.async` block, never the main actor | `applyMode`, `flipCamera` |
| a new photo variant | `capturePhoto` settings construction + a `PendingCapture.Kind` | the bracket/ProRAW branches |
| post-capture media work | `MediaProcessing` as a static func, called from a detached Task | `cropPreservingMetadata` |

## Gotchas — what a newcomer gets wrong here

1. **Never add `builtInTripleCamera`, `builtInTelephotoCamera`, or a 3x zoom stop.** That is
   the app's entire reason to exist (`CameraManager.swift:398` `bestDevice`,
   `CameraManager.swift:1064` `zoomStops`). An `AVCaptureDevice.DiscoverySession` that could
   pick a tele device is equally forbidden.
2. **Live Photo, depth delivery and `movieOutput` are mutually exclusive.** Adding
   `movieOutput` silently makes `isLivePhotoCaptureSupported` and
   `isDepthDataDeliverySupported` return `false`. Capability flags must therefore only be
   read while `movieOutput` is *out* of the session (`configureSession`, `flipCamera`) —
   `applyMode` deliberately does **not** re-read them (`CameraManager.swift:820`).
3. **Several AVFoundation misconfigurations throw NSException rather than returning an
   error** — an out-of-range `activeVideoMinFrameDuration`, a `flashMode` on a bracket
   capture, `maxPhotoDimensions` above what a bracket accepts, enabling Live Photo while
   responsive capture is on. The code clamps for each of these; removing a clamp is a crash,
   not a bug report. See `achievableFps` (`CameraManager.swift:916`).
4. **The main actor must never read `session.inputs` / `session.outputs`.** `applyMode`
   re-derives the current input from `session.inputs` inside `sessionQueue` precisely
   because `self.videoInput` is assigned from a `Task @MainActor` and lags
   (`CameraManager.swift:668`). `flipCamera` and `startRecording` still break this rule.
5. **UI state is published optimistically.** `displayZoom`, `torchOn`, `isLocked`,
   `exposureBias`, `isRecording`, `quickTakeAvailable` are all set before the
   `sessionQueue` work that would justify them, and nothing rolls them back when
   `lockForConfiguration()` fails. Do not read these as "the hardware is in this state".

## Index

- `10-business.md` — modes, capture rules and invariants, settings surface
- `20-api.md` — entry points, gestures, delegate surface (no HTTP in this project)
- `30-data-model.md` — persisted state: UserDefaults keys, temp files, Photos assets
- `40-conventions.md` — how code is written here
- `50-stack-patterns.md` — how this repo uses SwiftUI/AVFoundation
- Not generated: `25-fe-be-contract.md` — single repo, no frontend/backend split.

## Known unknowns

- No runtime verification is possible from this host; every behavioural claim in the pack
  is static. Device testing needs an iPhone 13 Pro + Xcode 26.
- Whether the tele lens truly stays unpowered can only be confirmed on hardware.
- `AUDIT_REPORT.md` and `REMEDIATION_PLAN.md` at the repo root (untracked at the time of
  writing) record 20 known defects; this pack describes the code as it is, not as it
  should be.
