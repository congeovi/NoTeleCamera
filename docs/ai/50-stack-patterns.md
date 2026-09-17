# NoTeleCamera — how this repo uses AVFoundation and SwiftUI

> Generated from 5c01e70 (2026-09-17) by project-onboard.
> Cache of the codebase, not a specification. Verify load-bearing claims against code.
> Refresh with: "refresh docs/ai".

This is the file to read before touching the capture pipeline. Most of it is
AVFoundation behaviour that is not obvious from the API surface, learned the hard way and
recorded in the code's own comments.

## The session graph

```
AVCaptureSession
├── AVCaptureDeviceInput(video)      one at a time; swapped on mode change and flip
├── AVCaptureDeviceInput(audio)      attached on entering video/slo-mo, removed on leaving
├── AVCapturePhotoOutput             always present
├── AVCaptureMovieFileOutput         present EXCEPT when Live Photo or depth is wanted
└── AVCaptureMetadataOutput          always present, delegate on .main
```

Preview is an `AVCaptureVideoPreviewLayer` inside `PreviewUIView`
(`CameraUI.swift:14`), bridged by `CameraPreview: UIViewRepresentable`.

### Rule 1 — `movieOutput` masks capabilities

With `movieOutput` in the session, `photoOutput.isLivePhotoCaptureSupported` and
`isDepthDataDeliverySupported` both report `false`. Therefore:

- `configureSession` and `flipCamera` read those flags **with movie output removed**
  (`CameraManager.swift:436`, `:1011`).
- `applyMode` explicitly refuses to re-read them (`CameraManager.swift:820`); doing so
  would permanently hide the Live Photo button after one trip through slo-mo.
- `configureSession` avoids adding `movieOutput` at all when the start mode is
  photo+Live or portrait+depth, because removing it right after `startRunning()`
  reconfigures a live session and resets `videoZoomFactor` to the ultra-wide 0.5x
  (`CameraManager.swift:444`).

### Rule 2 — several misconfigurations throw, they do not return errors

| Action | Throws when | Guard used |
|---|---|---|
| `activeVideoMinFrameDuration = d` | `d` is outside `activeFormat`'s ranges | `achievableFps` clamps to the real max (`CameraManager.swift:916`) |
| `photoSettings.flashMode = .on` | the settings are an AE bracket | forced to `.off` for brackets (`CameraManagerCapture.swift:152`) |
| `photoQualityPrioritization = .balanced` | above `photoOutput.maxPhotoQualityPrioritization` | compared against the ceiling first (`:161`) |
| `maxPhotoDimensions = ...` | a bracket does not accept that size | left at the format default for brackets (`:165`) |
| `isLivePhotoCaptureEnabled = true` | `isResponsiveCaptureEnabled` is still true | responsive/fast-prioritization are lowered first (`CameraManager.swift:770-776`) |
| `activeFormat = f` | `f` belongs to a different device | `activeDev.formats.contains(defFormat)` (`CameraManager.swift:723`) |

### Rule 3 — zoom is expressed in two coordinate systems

A virtual device's hardware `videoZoomFactor` of `virtualDeviceSwitchOverVideoZoomFactors.first`
is what the user calls "1x". The app stores that as `baseFactor` and converts:
`device.videoZoomFactor = displayZoom * baseFactor`. Re-read `baseFactor` after every
device swap — `applyMode` and `flipCamera` both do, and both force the device back to the
switch-over factor because AVFoundation resets zoom on renegotiation.

### Rule 4 — low-latency capture must be re-established after every reconfigure

`tuneForLowLatency` (`CameraManager.swift:385`) sets zero-shutter-lag -> responsive capture
-> fast-capture prioritization, in that dependency order. Toggling Live Photo or depth
invalidates them and AVFoundation does **not** restore them, so the helper is called at the
end of every configuration block. Without ZSL the app feels like a 2016 camera app.

## The still-capture pipeline

```
capturePhoto (main actor: snapshot mode/flash/EV/mirror/angle, bump capturesInFlight)
  └── sessionQueue: read the REAL output flags, build AVCapturePhotoSettings
        └── main actor: pendingCaptures[id] = pending; armWatchdog(id)
              └── sessionQueue: set connection angle/mirroring; photoOutput.capturePhoto
                    ├── willBeginCaptureFor        lower expectations if Live/RAW refused
                    ├── didFinishProcessingPhoto   processed and/or RAW data
                    ├── ...LivePhotoToMovieFileAt  paired video
                    └── didFinishCaptureFor        shorten the watchdog to 2 s
                          └── finishIfComplete -> savePhoto -> endCapture
```

Two non-negotiable details: settings are built **on `sessionQueue` reading live flags**
(building them on the main actor let `applyMode` change the flags in between, which threw),
and `pendingCaptures[id]` is written **before** `capturePhoto` (delegates can beat it).

### The EV trade-off

`setExposureTargetBias` only changes sensor exposure; the ISP tone-maps most of it back out
of the still. The app therefore uses `AVCapturePhotoBracketSettings` with a single
`AVCaptureAutoExposureBracketedStillImageSettings` step whenever EV != 0. A bracket cannot
coexist with Live Photo, depth, flash or ProRAW, so those are dropped for that frame and
the user is told (`CameraManagerCapture.swift:110-140`).

### Depth and portrait

Depth is delivered separately (`embedsDepthDataInPhoto = false`) and re-oriented with
`applyingExifOrientation` before use — the depth map arrives in sensor orientation while
the photo has already been rotated by `videoRotationAngle`, and skipping this puts the blur
in the wrong place (`CameraManagerCapture.swift:420`). `PortraitRenderer` then builds a
disparity mask (`CISubtractBlendMode` x2 -> `CIMaximumCompositing` -> `CIColorMatrix` gain ->
`CIGaussianBlur`) and applies `CIMaskedVariableBlur`. It is not Apple's portrait mode: there
is no neural person segmentation, so edges are soft.

## Video and slow motion

- Slo-mo needs `sessionPreset = .inputPriority` because the format is chosen by hand.
- `highFrameRateFormat` accepts a format whose `maxFrameRate` is slightly *below* the
  request (hardware advertises 239.76 for "240"), then `achievableFps` clamps the duration
  to the real maximum — because the duration setter is not forgiving.
- The achieved rate lives in `activeSlomoFps` and is **not** written back into
  `settings.slomoRate`: the front camera tops out at 120 fps, and persisting that would
  strand the rear camera at 120 too.
- Export (`MediaProcessing.slowDown`) builds an `AVMutableComposition`, scales the time
  range by `capturedFps / 30`, and drops audio entirely.

## Time-lapse

Stills on a timer rather than a long video: `captureTimeLapseFrame` every
`TimeLapseInterval.seconds`, each frame re-encoded to JPEG and written to a per-instance
folder, then assembled by `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` at
H.264 30 fps. Writing to disk instead of holding `UIImage`s is what makes long captures
possible. Note that output dimensions are taken from the **first** frame only, so rotating
the phone mid-capture distorts later frames.

## SwiftUI interop

| Need | Pattern |
|---|---|
| Preview layer | `UIViewRepresentable` over a `UIView` whose `layerClass` is `AVCaptureVideoPreviewLayer` (`CameraUI.swift:14`) |
| Tap / long-press with precise control | `UIGestureRecognizer` in the representable's coordinator, not SwiftUI gestures (`CameraUI.swift:53`) |
| Pinch | SwiftUI `MagnifyGesture` layered on top |
| Volume-button shutter | a hidden `MPVolumeView` (`HiddenVolumeView`) plus KVO on `AVAudioSession.outputVolume`, with the volume reset after each press |
| Audio-category changes | post `.cameraAudioSessionWillChange` first — switching to `playAndRecord` moves `outputVolume` between ringer and media scales, which `VolumeShutter` would otherwise read as a shutter press |

## Known rough edges in these patterns

Recorded so you do not mistake them for intended design; each is tracked in
`AUDIT_REPORT.md`:

- `flipCamera` captures `videoInput` on the main actor and uses it on `sessionQueue`;
  `applyMode` deliberately does not, and is the pattern to copy.
- `startRecording` reads `session.outputs` on the main actor.
- `isRecording` is set before `movieOutput.startRecording`, and
  `didStartRecordingTo` is not implemented.
- `TimeLapseRecorder.append` is fire-and-forget: `try? jpeg.write` and the `Bool` from
  `adaptor.append` are both discarded, and there is no generation id, so a late frame can
  land in the next recording.
- `CMTime(value: 1, timescale: CMTimeScale(actualFps))` truncates 239.76 to 239 — but note
  that the fix is **not** `CMTime(seconds: 1/239.76, preferredTimescale: 60000)`, which
  rounds back up to exactly 240 fps and is out of range. Use the frame-rate range's own
  `minFrameDuration`.
