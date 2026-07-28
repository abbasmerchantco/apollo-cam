# ApolloCam — Known Issues

State as of v0.85.

## Open

Nothing currently open. The rotate/save bug that headed this section since v0.6 is fixed in v0.85 — see below.

## Fixed in v0.85

### Rotate/save produced incorrect rotation

**Root cause:** `ImagePipeline.apply` built its `CIImage` with `CIImage(image:)`, which reads the underlying `CGImage` pixel buffer and ignores UIKit's `imageOrientation`. A camera capture is almost always `.right` (the sensor is landscape), so the buffer is a quarter-turn away from what the user sees. Every transform therefore ran in sensor space, and the result was written back out tagged `.up` — discarding the quarter turn the metadata would have supplied.

That accounts for both reported manifestations, which were always the same fault: the output lands exactly one 90° turn short of intent, which reads as "one turn fewer than I tapped" when rotating and as "rotated 90° anti-clockwise" when not.

**Why it looked like a preview/save divergence:** the preview path renders from `proxy`, and `ImagePipeline.preview(from:)` re-draws through `UIImage.draw(in:)`, which *does* honour `imageOrientation`. So the proxy arrives at `apply()` already normalized to `.up` and previews were correct. The save path renders from the untouched `original`, which is not. Two paths, two different pixel frames.

**Why the sign hypothesis was wrong:** `-turns * .pi / 2` is correct. Core Image's origin is bottom-left with +y up, so a negative angle rotates clockwise, matching `rotationQuarters`' documented meaning and the `rotate.right` button. Flipping the sign would have inverted the (already correct) preview, and would not have explained the earlier "one turn fewer" report at all — a sign error leaves a 180° rotation looking correct, whereas a fixed one-turn offset does not.

**Fix:** bake `imageOrientation` into the pixels at the top of `ImagePipeline.apply()` via `CIImage.oriented(_:)` before any transform, so both paths work in the same frame. `PhotoEditor.swift`.

### AI Adjust discarded the user's rotate/flip

`aiAdjust()` assigned `AdjustService`'s result wholesale onto `adj`. That result is built from a neutral `EditAdjustments()`, so `rotationQuarters` and `flipH` were reset to zero — the existing crop was carefully preserved, but orientation was not. Both are now carried across in `applySuggestion`.

## Fixed in v0.82

- Hold-to-compare-with-original in the photo editor flashed the original for an instant and immediately reverted, even while still held. Cause: `onLongPressGesture`'s `pressing` callback resets to `false` as soon as `minimumDuration` elapses, not on finger-up. Replaced with a raw `DragGesture(minimumDistance: 0)`.
- The edited photo displayed at a smaller size than the original once an AI-adjust note appeared, because the note/error bar was a sibling row competing for vertical space with the image. Moved to a bottom-pinned overlay inside the image area instead.
- No crop tool existed in the editor at all (not a regression, a gap) — added.
- The subject-detection box could grow large enough to sit over the settings button and scene-pill strip, and (being backed by a `GeometryReader`) blocked taps across its whole bounding rect rather than just its drawn strokes. Original fix was `.allowsHitTesting(false)` on the decorative pieces; the box itself was later removed entirely as part of the broader camera-screen redesign, so this is moot going forward but is documented here since it shipped as a standalone fix first.
- Camera screen redesigned away from a cluttered, jittery composition-overlay/tracking-box design toward a single calm coaching line, per direct product direction (see Roadmap for what's intentionally deferred from this pass).

## Known limitations (pre-existing, not addressed this pass)

- "Auto" composition-rule selection is heuristic (subject size/position), not a trained scene classifier (from `SETUP.md`).
- No accounts/sync — all data is local to the device.
