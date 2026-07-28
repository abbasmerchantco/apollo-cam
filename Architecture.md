# ApolloCam — Architecture

State as of v0.82.

## System overview

ApolloCam is a SwiftUI iOS app built around three screens — the live camera (`CameraScreen`), the photo editor (`PhotoEditor`), and the gallery (`GalleryView`) — backed by an on-device computer-vision pipeline (`SubjectDetector`) and two Claude-powered services (`AdviceService` for live coaching, `AdjustService` / `CritiqueService` for photo evaluation and one-shot edit suggestions).

## Camera screen (`CameraScreen.swift`)

As of v0.82 this follows a "Camera Coach" design: the live preview has no drawn overlays. Composition rules, subject detection, and the AI partner all previously rendered their own on-screen chrome (a full geometry overlay per rule, a tracking bounding box, a three-card tip stack, a scene-pill strip, a separate AI-partner card) — all of that has been consolidated into a single `coachingChip`, one line of text with an icon that reflects whichever signal is most relevant right now: on-device `GuidanceEngine` output by default, or an AI-partner tip (with its own loading/error states folded into the same line) when Coach mode is on.

Key pieces:
- `SubjectDetector` (`SubjectDetector.swift`) runs on-device detection (faces > animals > salient objects) off the camera's frame stream (`camera.onFrame`). Its output (`detector.subject`, `detector.selectedPoint`) still exists and still drives guidance — it's just not drawn anymore. Tapping the screen selects a subject; tapping near an existing selection clears it (there's no dedicated "×" button — the old visual box that carried it is gone). A tap produces a brief fading ring (`TapPulse`) instead of a persistent overlay.
- `GuidanceEngine.evaluate(...)` (external to this file) turns detector output + the active composition rule + scene into a `Guidance` value (`message`, `aligned`, `suggestedRule`, `tips`, etc.). Only `message`/`aligned`/`suggestedRule` are actively used in the current UI; `tips` and per-scene pill data are still computed but unconsumed by the view layer now.
- Composition rules (`CompositionRule` in `CompositionRules.swift`) still exist as a full 14-case enum with a `CompositionOverlay` drawing struct, but `CompositionOverlay` is no longer rendered on the camera screen — the geometry-on-preview approach was the main source of visual clutter and has been retired in favor of text coaching. The manual rule picker (`rulePicker` sheet) is curated down to a short list — Auto, Rule of thirds, Centered, Symmetry, Leading lines (`CameraScreen.curatedRules`) — rather than exposing all 14 cases.
- Scene override (landscape/street/macro pills) has no UI control anymore; `sceneOverride` remains in state (always `nil`) and scene detection is always automatic.
- The AI partner (`AdviceService`, `partnerHeartbeat()`) is unchanged internally — same heartbeat/stillness/token-gating logic — only its presentation changed (folds into `coachingChip`).
- Top bar is two icon-only circular buttons (rule picker, settings) — no persistent labeled pill.

## Photo editor (`PhotoEditor.swift`)

`EditAdjustments` is the non-destructive edit state: color/tone sliders, orientation (`rotationQuarters`, `flipH`), and now `cropRect` (normalized 0...1, top-left origin, relative to the image *after* orientation — `(0,0,1,1)` means no crop). `ImagePipeline.apply(_:to:)` is the single pure rendering function used for both the live small-proxy preview and the final full-resolution save; order of operations is normalize-orientation-metadata → orientation → crop → exposure → tone curve → color controls → warmth/tint → sharpen → vignette.

That first step matters more than it looks. Core Image works on the raw `CGImage` buffer and ignores UIKit's `imageOrientation`, so `apply()` bakes the orientation in with `CIImage.oriented(_:)` before touching anything else. Without it the two callers disagree: `proxy` reaches `apply()` already normalized (because `preview(from:)` re-draws through `UIImage.draw`, which honours orientation), while `original` does not — which is exactly the divergence that produced the long-running rotate/save bug fixed in v0.85. Anything added to this pipeline must stay downstream of that normalization. Rotation direction is set by `-turns * .pi / 2`: Core Image's origin is bottom-left with +y up, so the negative angle is what makes `rotationQuarters` clockwise.

`PhotoEditorView` holds `original` (full-res), `proxy` (small preview), and `rendered` (proxy + current adjustments applied). Hold-to-compare (press and hold the photo to see the original) uses a raw `DragGesture(minimumDistance: 0)` rather than `onLongPressGesture` — the latter resets its `pressing` state as soon as its `minimumDuration` elapses, before the finger lifts, which caused the comparison to flash and immediately revert. The AI-note/error bars are rendered as a bottom-pinned overlay inside the image area rather than separate stacked rows, so the displayed image is the same size whether or not a note is showing.

Crop is a distinct mode (`cropMode`) rather than a slider: entering it renders an orientation-only (uncropped) version of the proxy (`cropBase`) so the user always sees the full frame regardless of any crop already applied, overlays a draggable rect (`CropOverlay`, corner-handle resize + whole-rect move, all normalized to the image's actual on-screen content rect to account for `.scaledToFit()` letterboxing), and swaps the bottom row for Cancel/Reset/Apply controls. AI-adjust routes through `applySuggestion(_:note:crop:cropNote:)`, which carries the user's `rotationQuarters` and `flipH` across an incoming suggestion (`AdjustService` builds its result from a neutral `EditAdjustments()`, so a wholesale assignment would reset them) and preserves the current `cropRect` unless the AI proposed one of its own.

AI crop suggestions are analysed on the *un-rotated* proxy, so `AdjustService.Result.suggestedCrop` is in a different frame from `EditAdjustments.cropRect`, which is defined after orientation. `ImagePipeline.orientedCropRect(_:quarters:flipH:)` maps between them at apply time — each clockwise quarter turn sends a normalized `(u, v)` to `(1 - v, u)`, mirroring first to match `apply()`'s order. The un-oriented rect is what gets cached on `PhotoEntry.aiCropRect` (deliberately *not* folded into `aiAdjustments.cropRect`, which means something else), so a cached suggestion stays correct if the user rotates the photo after asking for it.

## Known gaps

See `Known Issues.md`.
