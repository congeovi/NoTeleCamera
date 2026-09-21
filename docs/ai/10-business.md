# NoTeleCamera — domain rules

> Generated from 5c01e70 (2026-09-17) by project-onboard.
> Cache of the codebase, not a specification. Verify load-bearing claims against code.
> Refresh with: "refresh docs/ai".

The product spec lives in `func_req.md` (Vietnamese, 24 numbered sections). This file
records what the **code** actually enforces, and flags where the two disagree.

## The one invariant

> The 77 mm telephoto lens must never be selected, at any zoom, in any mode.

Enforced structurally, not by hiding UI:

| Situation | Device chosen | Where |
|---|---|---|
| Rear, any mode except slo-mo | `builtInDualWideCamera`, falling back to `builtInWideAngleCamera` | `CameraManager.swift:398-408` |
| Rear, slo-mo | `builtInWideAngleCamera` (virtual dual-wide has no 120/240 fps formats) | `CameraManager.swift:403` |
| Front | `builtInWideAngleCamera` | `CameraManager.swift:400` |

No `AVCaptureDevice.DiscoverySession` exists anywhere in the codebase; every device comes
from an explicit `AVCaptureDevice.default(_:for:position:)`. Zoom is capped at 5x
(`maxDisplayZoom`, `CameraManager.swift:136`) and the stop list never contains 3x
(`zoomStops`, `CameraManager.swift:1064`).

## Modes

`CaptureMode` (`CaptureTypes.swift:13`), display order time-lapse, slo-mo, video, photo,
portrait. `isRecordingMode` (video, slo-mo, time-lapse) makes the shutter a toggle.

| Mode | Device | Session preset | Output | Notes |
|---|---|---|---|---|
| photo | dual wide | `.photo` | `photoOutput` | Live Photo, ProRAW, macro, QuickTake, burst, timer all live here |
| portrait | dual wide | `.photo` | `photoOutput` + depth | `movieOutput` removed; blur rendered in-app, not by Apple |
| video | dual wide | quality preset | `movieOutput` | 1080p30 / 1080p60 / 4K30, stereo mic (iOS 18+) |
| slo-mo | wide 1x | `.inputPriority` | `movieOutput` | 120/240 fps, format picked by hand, audio dropped on export |
| time-lapse | dual wide | 1080p | `photoOutput` (stills on a timer) | frames written to disk, assembled to H.264 30 fps |

Mode changes go through `applyMode` (`CameraManager.swift:624`), which is guarded by
`isModeTransitioning` + a generation counter + a 2-second watchdog so a slow reconfigure
cannot leave the preview permanently blurred.

## Rules the code enforces

| Rule | Where | Notes |
|---|---|---|
| Live Photo / depth and `movieOutput` cannot coexist; movie output is removed when either is wanted | `CameraManager.swift:757-764` | this is also why capability flags must be read with movie output detached |
| QuickTake is unavailable whenever Live Photo is on | `CameraManager.swift:648` `quickTakeAvailable = !wantsLive` | published *before* the graph commits — see 00 Gotcha 5 |
| A QuickTake clip is at least 1.0 s long | `CameraManager.swift:1372` `quickTakeMinimumDuration` | early release waits out the remainder |
| Macro only in rear + photo mode + a device with an ultra-wide constituent; forces 0.5x; auto-off above 0.6x | `macroAvailable` `CameraManager.swift:1114`, `setMacro` `:948`, `setZoom` `:1051` | leaving photo mode also clears `.near` focus restriction |
| Any non-zero EV uses an AE bracket, which forfeits Live Photo, depth, flash and ProRAW for that frame | `CameraManagerCapture.swift:110-140` | deliberate trade-off; user is told when EV cannot be honoured |
| Aspect crop is skipped for Live Photo and ProRAW (would break the pair / cannot crop RAW) | `aspectCropSkipped` `CameraManager.swift:1088` | **duplicated** in `savePhoto`'s `shouldCrop` — see Divergences |
| Time-lapse needs >= 2 frames to produce a video | `CameraManager.swift:1554` | otherwise a status message and cleanup |
| Burst: 120 ms cadence, at most 4 captures in flight | `CameraManager.swift:1400-1410` | `burstCount` counts *submitted* requests, not saved photos |
| Video recording is refused when `movieOutput` is not in the session, or slo-mo has no achievable fps | `CameraManager.swift:1436-1451` | |
| Scanning is suppressed while recording and when the setting is off | `CameraManager.swift:1770` | delegate-side only; the metadata output keeps processing frames |

## Actors and permissions

One actor: the phone's owner. No accounts, no roles, no authorization logic. OS
permissions requested at `start()` (`CameraManager.swift:230-236`): camera (blocking —
refusal shows an error and stops), microphone, Photos add-only, location when-in-use. All
four usage strings are present in `Info.plist`.

## Where code and `func_req.md` disagree

These are intentional-looking divergences, each confirmed in both files:

| Spec | Code | Verdict |
|---|---|---|
| `func_req.md:114` "lock capture orientation to portrait (`videoRotationAngle = 90`)" | `AVCaptureDevice.RotationCoordinator` drives `captureRotationAngle` (`CameraManager.swift:283`) | code is arguably better; spec is stale |
| `func_req.md:184` "mic is attached immediately before recording and detached after" | mic is attached on *entering* video/slo-mo mode and kept between takes (`CameraManager.swift:644`, `:1707`) | privacy-relevant; code deviates |
| `func_req.md:232` "torch, EV and AE/AF lock are reset after a device swap" | EV and lock are reset, but torch is **re-enabled** on the new device (`CameraManager.swift:827`) | code deviates |
| `func_req.md:337` "settings sheet is half-screen" | `.presentationDetents([.medium, .large])` (`CameraUI.swift:1584`) | minor |
| `outputAspectRatio` / `aspectCropSkipped` described as the single source of truth (`CameraManager.swift:1071`) | `savePhoto` re-derives its own `shouldCrop = aspect != .r4x3 && raw == nil && liveMovie == nil` (`CameraManagerCapture.swift:305`) | genuinely two sources; they diverge for an EV-bracketed frame taken with Live Photo on |

## Glossary

| Term | Meaning |
|---|---|
| **NoTele** | the project's governing rule: the telephoto lens is never selected |
| **switch-over factor** | `virtualDeviceSwitchOverVideoZoomFactors.first` — the hardware zoom value that equals the user-facing "1x" on a virtual device; stored as `baseFactor` |
| **display zoom** | user-facing multiplier (0.5x / 1x / 2x); `deviceZoom = displayZoom * baseFactor` |
| **QuickTake** | hold the shutter in photo mode to record a short video |
| **PendingCapture** | the accumulator that gathers a single shutter press's processed photo + RAW + Live Photo movie before saving once |
| **generation** | a monotonically increasing id used to stop a stale async completion from acting on newer state (`modeTransitionGeneration`) |
