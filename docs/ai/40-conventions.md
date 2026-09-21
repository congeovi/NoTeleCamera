# NoTeleCamera — coding conventions

> Generated from 5c01e70 (2026-09-17) by project-onboard.
> Mined from the repo's own code. No linter or formatter is configured, so these are
> observed conventions, not enforced ones. Refresh with: "refresh docs/ai".

## Layout

Flat. Every Swift file sits at the repo root; there are no directories for source. Six
files, split by responsibility rather than by layer:

```
App.swift                    @main, plus a file-header manifest of the other files
CaptureTypes.swift           value types + persistence
CameraManager.swift          the session/state core
CameraManagerCapture.swift   `extension CameraManager` — the still-photo path
MediaProcessing.swift        pure-ish post-processing helpers
CameraUI.swift               every view, overlay and gesture
```

`project.yml` globs `path: .` and excludes `**/*.md`, `project.yml`, `Info.plist`,
`.git/**`, `.github/**` — **a new `.swift` file at the root is picked up automatically, and
so is one you did not intend to ship.** Anything added under a new directory is also
included unless excluded.

## Language

| Convention | Observed | Example |
|---|---|---|
| Comments and user-facing strings | **Vietnamese**, throughout | `errorMessage = "Luu anh that bai: ..."` |
| Identifiers | English, `lowerCamelCase` / `UpperCamelCase` | `bestHighFrameRateFormat` |
| Enum raw values | user-visible Vietnamese or a display string | `case fast = "0,5s"` |
| Doc comments | `///` on almost every non-trivial member, explaining *why*, often naming the bug the code fixes | `CameraManager.swift:88-96` |
| Section markers | `// MARK: - Title` at every logical break; `// MARK: Title` for sub-sections | throughout |

Comment density here is unusually high and deliberately so: most `///` blocks record an
AVFoundation trap and what went wrong before. **Match that when you edit** — a change that
removes a clamp without explaining why reads as a regression.

## Concurrency

The single most important convention in the codebase.

- `CameraManager` is `@MainActor`. All `@Published` state is main-actor state.
- Anything touching `AVCaptureSession`, `AVCaptureDevice` configuration, or connections
  runs inside `sessionQueue.async` (a serial `DispatchQueue`), never on the main actor.
- Crossing back is always `Task { @MainActor in ... }`.
- `nonisolated` marks members intentionally reachable from `sessionQueue` or from a
  delegate callback (`nonisolated let session`, `nonisolated static func bestDevice`).
- Values are **snapshotted on the main actor before** the hop, never read across it:
  `let front = isFront`, `let angle = captureRotationAngle` (`CameraManager.swift:637-645`).
  `MainActor.assumeIsolated` is explicitly banned — the header comment at
  `CameraManager.swift:626` records that it trapped.
- Non-`Sendable` values cross actor boundaries in `UncheckedBox<T>`
  (`CameraManagerCapture.swift:54`) rather than by disabling concurrency checking.
- Long CPU work (portrait render, crop, thumbnail) runs in `Task.detached(priority:
  .utility)` and hops back only to assign the result.

## Error handling

Three tiers, applied by consequence rather than uniformly:

| Tier | Form | When |
|---|---|---|
| Surfaced | `errorMessage` (alert) or `statusMessage` (transient toast) | anything the user must know: save failed, camera unavailable, mode unsupported |
| Swallowed deliberately | `try?` on device configuration and temp-file deletion | when failure is genuinely inert |
| Typed | `enum MediaError: LocalizedError` with a Vietnamese `errorDescription` | the post-processing layer only |

`try?` is the house idiom for `lockForConfiguration()`; the corresponding UI state is
generally **not** rolled back on failure. That is a known defect, not a convention to copy —
new code should prefer a `Result` and an explicit rollback.

## Defensive patterns to follow

1. **Capability-check before every AVFoundation set**: `isFocusPointOfInterestSupported`,
   `canAddInput`, `canSetSessionPreset`, `supportedFlashModes.contains`,
   `availablePhotoCodecTypes.contains`. Several of these throw `NSException` if skipped.
2. **Write-only-if-different**: `if conn.videoRotationAngle != angle { ... }`,
   `if self.session.sessionPreset != preset { ... }` — redundant writes make AVFoundation
   renegotiate and flush the zero-shutter-lag buffer.
3. **Generation counters instead of cancellation flags** for anything a user can retrigger
   (`modeTransitionGeneration`).
4. **A watchdog for every callback you do not control** (`armWatchdog`,
   `modeTransitionWatchdog`).
5. **Register state before triggering the callback** — `pendingCaptures[id]` is written
   before `capturePhoto`, because the delegate can arrive first.
6. **`autoreleasepool` in every frame loop** (`MediaProcessing.swift:163`, `:238`).

## SwiftUI conventions

- One `@StateObject var cam = CameraManager()` in `ContentView`; every child takes
  `@ObservedObject var cam` or plain values. No environment objects, no view models.
- Overlays are small `struct ... : View` types in `CameraUI.swift`, not nested closures.
- Animations are explicit `withAnimation(.easeOut(duration:))` around the state change, or
  `.animation(_:value:)` bound to a specific published property.
- Magic numbers that encode a design decision become `static let` with a comment
  (`evDragPointsPerStop`, `pitchFadeStart`, `levelThresholdOn/Off`).

## Tests

None. There is no test target, no XCTest import, and no way to run tests in CI. New work
is verified by `swiftc -frontend -parse`, the CI archive, and manual device testing.

## Git

- Branch: work lands on `main`; feature branches use `fix/<slug>` per
  `REMEDIATION_PLAN.md`.
- Commit subjects are short, mixed Vietnamese/English, imperative-ish
  (`Add support for slow-motion mode...`, `Sua loi va don dep sau review ban UI iOS 26`).
- A local `commit-msg` hook strips agent `Co-Authored-By` / `Generated with` trailers —
  do not add them.
