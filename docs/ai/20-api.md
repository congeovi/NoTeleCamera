# NoTeleCamera — entry-point surface

> Generated from 5c01e70 (2026-09-17) by project-onboard.
> Cache of the codebase, not a specification. Verify load-bearing claims against code.
> Refresh with: "refresh docs/ai".

**There is no HTTP, GraphQL, gRPC, webhook, queue or CLI surface in this project.** It is a
single-process iOS app with no network code of any kind (no `URLSession`, no sockets). What
follows is the equivalent surface: the ways control enters the app.

## Process entry

| Kind | Symbol | File |
|---|---|---|
| App launch | `NoTeleCameraApp` (`@main`) | `App.swift:35` |
| Scene lifecycle | `.onChange(of: scenePhase)` -> `cam.start()` / `cam.stop()` | `CameraUI.swift:593` |
| View lifecycle | `.onAppear` / `.onDisappear` | `CameraUI.swift:582-589` |

`.inactive` is deliberately unhandled (`default: break`) — pulling down Control Center does
not stop the session.

## Public surface of `CameraManager`

The single object the UI talks to. Everything is `@MainActor`.

| Method | Effect | Guards |
|---|---|---|
| `start()` / `stop()` | build or resume the session; stop motion, countdown, burst, recording | `isConfigured`, `isConfiguring` |
| `setMode(_:)` | switch capture mode, persist it, drop torch for non-video modes | `!isRecording`, `!isProcessing` — **not** `!isBursting` |
| `reconfigure()` | re-apply the current mode after a setting change (Live Photo, video quality) | `!isRecording`, `!isProcessing` |
| `flipCamera()` | swap front/rear, re-read capabilities, re-apply mode | `!isRecording`, `!isProcessing`, `videoInput != nil` |
| `setZoom(_:)` / `pinchZoom(scale:from:)` | clamp to `[minAvailable/base, min(5, maxAvailable/base)]`, cancel macro above 0.6x | device present |
| `focus(at:uiPoint:)` | one-shot AF/AE at a point, reset EV, schedule indicator hide | device present |
| `lockFocusAndExposure(at:uiPoint:)` / `unlock()` | AE/AF lock badge | device present |
| `setExposureBias(_:)` | clamp to +/-2 EV, deduplicate against `lastPushedBias` | device present |
| `setTorch(_:)` | torch on/off | `device.hasTorch` |
| `cycleFlash()` | auto -> on -> off | none |
| `setMacro(_:)` | toggle `.near` focus restriction, force 0.5x | `macroAvailable` when turning on |
| `shutterTapped()` | mode-dependent: toggle recording, cancel countdown, capture, or start timer | |
| `shutterHoldBegan()` / `shutterHoldEnded()` | QuickTake start / stop with 1 s minimum | photo mode, `quickTakeAvailable`, not recording/bursting/counting down |
| `burstBegan()` / `burstEnded()` | 120 ms loop with 4-in-flight backpressure | photo mode, not recording/bursting |
| `capturePhoto(isBurst:)` | the whole still pipeline | `isBurst \|\| !isCapturing`, session running |
| `cancelCountdown()` / `keepFocusAlive()` / `scheduleFocusHide(after:)` | UI timing helpers | |
| `saveVideo(_:)` | write a movie to Photos and delete the source | |
| `detachAudio(onDone:)` | remove every audio input, return the audio session to `.ambient` | `audioAttached` |

Published state the UI observes: `settings`, `displayZoom`, `torchOn`, `exposureBias`,
`isLocked`, `lastThumbnail`, `focusPoint`, `isCapturing`, `shutterFlashTrigger`, `isFront`,
`errorMessage`, `statusMessage`, `activeSlomoFps`, `captureRotationAngle`, `isRecording`,
`isQuickTake`, `recordDuration`, `isProcessing`, `timeLapseFrames`, `countdown`,
`isBursting`, `burstCount`, `rollAngle`, `isLevel`, `orientationAngle`, `levelPitchFade`,
`scannedCode`, `supportsProRAW`, `supportsLivePhoto`, `supportsDepth`, `supportsMacro`,
`quickTakeAvailable`, `isModeTransitioning`.

## Gesture surface (`CameraUI.swift`)

| Gesture | Target | Action |
|---|---|---|
| Tap | preview | focus + expose at point (`CameraPreview` coordinator, `:53`) |
| Long press 0.6 s | preview | AE/AF lock |
| Vertical one-finger drag beside the focus square | preview | EV, 90 pt per stop (`evDragPointsPerStop`, `CameraManager.swift:1124`) |
| Horizontal swipe ~60 pt | preview | step one mode |
| Pinch (`MagnifyGesture`) | preview | continuous zoom (`CameraUI.swift:651`) |
| Tap | shutter | capture / toggle recording |
| Long press 0.45 s | shutter | QuickTake (`CameraUI.swift:1358`) |
| Drag left > 25 pt | shutter | burst (`CameraUI.swift:1337`) |
| Volume up/down | hardware | shutter, via `AVAudioSession.outputVolume` KVO (`CameraUI.swift:393`) |

The drag and long-press recognisers on the shutter run `simultaneousGesture`, so around the
0.45 s threshold both can fire; there is no shared flag between them.

## System callbacks the app implements

| Protocol | Methods | File |
|---|---|---|
| `AVCapturePhotoCaptureDelegate` | `willBeginCaptureFor`, `didFinishProcessingPhoto`, `didFinishProcessingLivePhotoToMovieFileAt`, `didFinishCaptureFor` | `CameraManagerCapture.swift:390-497` |
| `AVCaptureFileOutputRecordingDelegate` | `didFinishRecordingTo` only — **`didStartRecordingTo` is not implemented**, so `isRecording` is set optimistically | `CameraManager.swift:1697` |
| `AVCaptureMetadataOutputObjectsDelegate` | `didOutput metadataObjects` | `CameraManager.swift:1764` |
| NotificationCenter | `AVCaptureSessionRuntimeError`, `AVCaptureSessionWasInterrupted`, `AVCaptureSessionInterruptionEnded`, `AVCaptureDevice.subjectAreaDidChangeNotification` | `CameraManager.swift:296-380` |
| Custom | `.cameraAudioSessionWillChange` — posted before every audio-category change so `VolumeShutter` ignores the resulting volume jump | `CameraManager.swift:38` |

## Scanned code types

`[.qr, .ean13, .ean8, .code128, .pdf417, .dataMatrix]`, intersected with
`availableMetadataObjectTypes` (`CameraManager.swift:465`). The banner label collapses all
of them to "Ma QR" or "Ma vach" (`CaptureTypes.swift:128`).

## Outbound

| Target | Call | Note |
|---|---|---|
| Photos library | `PHAssetCreationRequest` with `.photo`, `.alternatePhoto` (DNG), `.pairedVideo` (Live Photo), `.video` resources | the only place media leaves the app |
| `photos-redirect://` | `openURL` on the thumbnail (`CameraUI.swift:1278`) | undocumented scheme |
| `UIPasteboard` | copy a scanned code that is not a URL | |
| `openURL` | open a scanned http/mailto/tel code | |
