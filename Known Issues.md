# ApolloCam — Known Issues

State as of v0.82.

## Open

### Rotate saves with one fewer turn than executed (unconfirmed cause)
Reported: rotating the photo in the editor and saving sometimes produces an image rotated one 90° turn less than the number of times the rotate button was tapped.

Investigated: `EditAdjustments.rotationQuarters` is absolute (not compounded), and `ImagePipeline.apply` recomputes rotation fresh from the untouched `original`/`proxy` every time — both the live preview render and the final save read the same `adj` snapshot synchronously, so no arithmetic or obvious race was found by inspection. Root cause is not yet confirmed. Next step before attempting a fix: reproduce with logging (`adj.rotationQuarters` at each tap vs. at the moment `save()` captures its snapshot) to see exactly where the count diverges, rather than guessing. Explicitly out of scope for the v0.82 changes below — left untouched per instruction.

## Fixed in v0.82

- Hold-to-compare-with-original in the photo editor flashed the original for an instant and immediately reverted, even while still held. Cause: `onLongPressGesture`'s `pressing` callback resets to `false` as soon as `minimumDuration` elapses, not on finger-up. Replaced with a raw `DragGesture(minimumDistance: 0)`.
- The edited photo displayed at a smaller size than the original once an AI-adjust note appeared, because the note/error bar was a sibling row competing for vertical space with the image. Moved to a bottom-pinned overlay inside the image area instead.
- No crop tool existed in the editor at all (not a regression, a gap) — added.
- The subject-detection box could grow large enough to sit over the settings button and scene-pill strip, and (being backed by a `GeometryReader`) blocked taps across its whole bounding rect rather than just its drawn strokes. Original fix was `.allowsHitTesting(false)` on the decorative pieces; the box itself was later removed entirely as part of the broader camera-screen redesign, so this is moot going forward but is documented here since it shipped as a standalone fix first.
- Camera screen redesigned away from a cluttered, jittery composition-overlay/tracking-box design toward a single calm coaching line, per direct product direction (see Roadmap for what's intentionally deferred from this pass).

## Known limitations (pre-existing, not addressed this pass)

- "Auto" composition-rule selection is heuristic (subject size/position), not a trained scene classifier (from `SETUP.md`).
- No accounts/sync — all data is local to the device.
