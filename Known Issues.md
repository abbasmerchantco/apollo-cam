# ApolloCam — Known Issues

State as of v0.90.

## Open

### Untested on device (v0.90)

None of the v0.90 photo-editor or gallery work has been run on real hardware yet, and the editor changes in particular involve enough trigonometry to be worth deliberate testing rather than assuming the analytical derivation is correct:

- The straighten auto-zoom-to-cover scale and the crop+straighten composition (`ImagePipeline.orientedCropRect`) were derived and sanity-checked on paper (corner-containment inequalities, a 90° matrix sanity check), not verified against a real rendered photo. Test with a genuinely off-vertical shot at several straighten angles, with and without an accompanying AI-suggested crop, and confirm verticals actually land level and the crop lands where expected — not just close.
- Swipe-to-select in the gallery (`GalleryView`) hasn't been tested against `LazyVGrid`'s lazy rendering — cell frames are only known for currently-rendered cells, so a fast scroll immediately followed by a drag could in principle miss cells that haven't rendered yet. Likely a non-issue in practice (you can only usefully select what's on screen) but unconfirmed.

### AI vertical/horizon detection is unvalidated

AI Adjust's prompt was broadened in v0.90 to actively look for *any* off-level vertical or horizontal reference — building edges, doorframes, poles, a horizon — rather than only an obvious tilted horizon, after real use turned up a photo of a slightly-off, off-centre building that the original (horizon-only, "return 0 unless you can actually see the tilt") wording didn't correct. The crop suggestion was also extended to consider symmetry/centering, not just dead space or an off-balance subject. Whether the broadened prompt reliably catches subtle tilts, and whether the crop-for-symmetry addition helps or adds noise, is the kind of thing only real shooting across a variety of photos answers — same category of open question as the AI crop threshold below.

### Untested on device (v0.88)

None of the v0.88 camera work has been run on real hardware yet. The zoom rework in particular is the kind of change that can only be judged on a physical phone:

- The display/device zoom mapping is derived from `virtualDeviceSwitchOverVideoZoomFactors`, which the simulator does not provide. On the simulator the app falls back to the single wide-angle path (stops `1/2/3`, no 0.5×) — that fallback is *expected* there and is not evidence of a bug.
- The derived stops should be checked against the stock camera app on each device to hand: a dual-wide phone should offer `0.5/1/2`, a triple-camera Pro `0.5/1/2/5`.
- `ramp(toVideoZoomFactor:withRate:)` is used for button taps and the Coach pull-back. The published `zoomFactor` is set to the target immediately rather than tracking the ramp, so the label leads the lens by a few hundred milliseconds by design. If that reads as laggy or jumpy in practice, the rate (currently 6) is the thing to tune.

### AI-suggested zoom is unvalidated

Claude now returns a zoom alongside its coaching tip. The prompt biases it toward real lens stops and toward tighter framing, on the theory that beginners shoot too wide. Whether it's right often enough to be worth a button is an open question that only real shooting answers. The chip is suppressed when the suggestion is within 12% of the current zoom, so a badly-calibrated model shows up as a chip that never appears rather than one that fights the user.

## Fixed in v0.90

### `EditAdjustments` schema changes could have silently emptied the gallery

**Root cause:** `EditAdjustments` relied on synthesized `Codable`. Swift's synthesized `Decodable` requires every stored property's key to be present in the decoded JSON regardless of whether the property has a default value — easy to miss, since the memberwise initializer (used everywhere `EditAdjustments()` appears in code) happily uses those defaults. `PhotoStore.load()` decodes the entire `[PhotoEntry]` array in a single call and swallows any failure with `try?`, treating it as "no saved entries." So the moment any field was added to `EditAdjustments` — as `straighten` needed to be, for this version's precise-rotation work — every `PhotoEntry` saved by a prior build would fail to decode, and the whole persisted gallery index would silently come back empty on next launch.

**Fix:** `EditAdjustments` now has a custom `init(from:)` that reads each field via `decodeIfPresent(...) ?? default`, making every key optional at decode time regardless of the stored property's own type. This was never exercised by a real schema change before now — `rotationQuarters`, `flipH`, and `cropRect` had presumably each carried the same latent risk when they were originally added — so the fix covers those retroactively too, not just `straighten`. Any field added to this struct going forward should follow the same pattern.

## Fixed in v0.88

### Composition guide drew no overlay

Selecting a guide from the camera's composition sheet changed the coaching text and the top-bar icon but rendered nothing on the preview.

**Root cause:** not a rendering bug — a leftover. v0.82 retired `CompositionOverlay` from the camera screen deliberately (the drawn geometry was the main source of visual clutter) but kept the picker sheet, still titled "Composition guide". From then on the control had no drawn output to change; `CompositionOverlay` remained in `CompositionRules.swift`, fully implemented and never instantiated.

**Fix:** `CompositionOverlay` gained a `Style` — `.reference` (hairline white, no target rings) for the always-on grid, `.guide` (the original cyan/green with rings) for a rule the user chose. `CameraScreen` renders it again, gated on a `showCompositionGrid` setting. Auto mode is pinned to a static thirds grid rather than following `guidance.suggestedRule`, which re-evaluates ~4×/second and would otherwise swap the overlay's entire geometry mid-frame — the same instability that motivated removing overlays in the first place.

### 0.5× was unreachable

`CameraController` only ever opened `.builtInWideAngleCamera`, whose `minAvailableVideoZoomFactor` is 1.0. No amount of UI work could expose an ultra-wide, because the ultra-wide was never part of the capture session. Fixed by preferring the widest available *virtual* device (triple → dual-wide → dual → wide) and mapping between device zoom and the display zoom the user reads.

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
