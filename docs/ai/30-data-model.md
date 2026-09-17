# NoTeleCamera — persisted state

> Generated from 5c01e70 (2026-09-17) by project-onboard.
> Cache of the codebase, not a specification. Verify load-bearing claims against code.
> Refresh with: "refresh docs/ai".

**There is no database, no ORM and no migration tool.** Persistence is three things:
UserDefaults for settings, the filesystem's temporary directory for in-flight media, and
the Photos library for output. All of it is in `CaptureTypes.swift` and the save paths.

## UserDefaults — `CameraSettings`

`CaptureTypes.swift:136-201`. Flat keys on `UserDefaults.standard`, no suite, no
versioning, no migration path. Loaded once in `start()`; every mutation path calls
`save()`, which writes the whole struct.

| Key | Swift field | Type stored | Default | Notes |
|---|---|---|---|---|
| `mode` | `mode` | String raw value | `.photo` | invalid value falls back to default |
| `flash` | `flashMode` | Int raw value | `.auto` | presence-checked with `object(forKey:)` because 0 is a valid mode |
| `aspect` | `aspect` | String | `.r4x3` | `4:3` / `16:9` / `1:1` |
| `grid` | `gridOn` | Bool | `false` | |
| `level` | `levelOn` | Bool | `false` | |
| `timer` | `timerOption` | Int (0/3/10) | `.off` | |
| `videoQuality` | `videoQuality` | String | `1080p30` | `1080p30` / `1080p60` / `4K30` |
| `slomo` | `slomoRate` | String | `240 fps` | user's *choice*; the achieved rate is `activeSlomoFps`, deliberately not persisted |
| `timelapse` | `timeLapseInterval` | String | `1s` | `0,5s` / `1s` / `3s` |
| `photoFormat` | `photoFormat` | String | `HEIF` | `HEIF` / `ProRAW` |
| `livePhoto` | `livePhotoOn` | Bool | `true` | presence-checked (default is true) |
| `macro` | `macroOn` | Bool | `false` | force-cleared when leaving photo mode or flipping to front |
| `scanCodes` | `scanCodesOn` | Bool | `true` | presence-checked |
| `portraitIntensity` | `portraitIntensity` | Float | `0.6` | presence-checked |

Renaming a key silently resets that setting for existing users — there is no migration
hook. Adding a field means four edits: the property, `Key`, `load()`, `save()`.

## Temporary files

All under `FileManager.default.temporaryDirectory`. Ownership is implicit — there is no
central registry and no startup sweep.

| Prefix | Created by | Deleted by | Leak conditions |
|---|---|---|---|
| `rec_<uuid>.mov` | `startRecording` (`CameraManager.swift:1461`) | `saveVideo` completion, or the error branch of `didFinishRecordingTo` | deleted even when the Photos save fails |
| `slomo_<uuid>.mov` | `MediaProcessing.slowDown` (`MediaProcessing.swift:56`) | `saveVideo` completion | left behind when the export does not reach `.completed` |
| `live_<uuid>.mov` | `capturePhoto` when Live Photo is on (`CameraManagerCapture.swift:182`) | consumed by PhotoKit with `shouldMoveFile = true`; deleted on abort/watchdog/failure | left behind if the Photos save fails after the resource was added |
| `timelapse_<uuid>/` | `TimeLapseRecorder.init` (`MediaProcessing.swift:152`) | `reset()` deletes the *files* | the **directory itself is never removed**; files leak when `assemble()` throws |
| `timelapse_<uuid>.mov` | `TimeLapseRecorder.assemble` (`MediaProcessing.swift:181`) | `saveVideo` completion | partial file left if the writer fails mid-way |

Frame files inside a time-lapse folder are named `f_<index>.jpg` where the index is
`frameURLs.count` at append time (`MediaProcessing.swift:165`) — so indices restart after
`reset()` and a stale append can overwrite a new generation's frame.

## Photos library (the output store)

Add-only authorization (`PHPhotoLibrary.requestAuthorization(for: .addOnly)`). One
`PHAssetCreationRequest` per capture:

| Asset shape | Resources | Built in |
|---|---|---|
| Plain photo | `.photo` (HEIF, or JPEG when re-encoded by the portrait/crop fallback) | `savePhoto` |
| ProRAW photo | `.photo` + `.alternatePhoto` with `uniformTypeIdentifier = AVFileType.dng` | `savePhoto` |
| Live Photo | `.photo` + `.pairedVideo` (`shouldMoveFile = true`) | `savePhoto` |
| Video / slo-mo / time-lapse | `.video` from a file URL | `saveVideo` |

Every asset gets `req.location = currentLocation` — read straight from
`CLLocationManager.location` with no age or accuracy check, and location updates are never
stopped when the app backgrounds.

## In-memory state worth knowing

| Structure | Purpose | File |
|---|---|---|
| `pendingCaptures: [Int64: PendingCapture]` | keyed by `AVCapturePhotoSettings.uniqueID`; gathers processed photo + RAW + Live Photo movie + depth before a single save | `CameraManagerCapture.swift:32` |
| `captureWatchdogs: [Int64: Task]` | 8 s (2 s after `didFinishCaptureFor`) rescue timer per capture, so a never-arriving piece cannot wedge the shutter | `CameraManagerCapture.swift:214` |
| `capturesInFlight: Int` | drives the shutter's enabled state and burst backpressure | `CameraManager.swift:187` |
| `modeTransitionGeneration: Int` | stops a stale `applyMode` completion clearing a newer transition's flag | `CameraManager.swift:114` |
