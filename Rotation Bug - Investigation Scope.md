# Rotation Bug — Investigation Scope

> **RESOLVED in v0.85 — Hypothesis 2 was correct.**
>
> `CIImage(image:)` reads the raw `CGImage` and ignores `imageOrientation`, so a `.right` camera capture was transformed in sensor space and written back out as `.up`, landing exactly one quarter turn short of intent. Fixed by baking orientation in with `CIImage.oriented(_:)` at the top of `ImagePipeline.apply()`.
>
> **Hypothesis 1 (the recommended first fix) was wrong, and testing it first would have made things worse.** `-turns * .pi / 2` is correct: Core Image's origin is bottom-left with +y up, so a negative angle rotates clockwise. The preview path was already producing correct rotation with that sign — flipping it would have broken the one path that worked. The reasoning in "Recommended First Fix" below also assumed the bug would have been caught in v0.1 testing if the sign were intentional; rotation actually shipped in v0.6, and `ImagePipeline.preview(from:)` re-draws through `UIImage.draw`, which normalizes orientation. That is what kept the preview honest and hid the fault on the save path.
>
> The decisive evidence was the *earlier* report, not the newer one: "one 90° turn fewer than tapped" is a fixed one-turn offset, which a sign inversion cannot produce (under a sign error, a 180° rotation still looks correct). Kept below as a record of the investigation.

---

**Issue:** Editing a picture and saving it results in the image rotated 90° counter-clockwise, regardless of user intent.

**Symptom specificity:** User taps rotate once (expecting 90° clockwise) → saved image is 90° counter-clockwise.

---

## Root Cause Hypotheses

### Hypothesis 1: Angle Sign Inverted (Most Likely)

**Code location:** `PhotoEditor.swift`, lines 70–77

```swift
let turns = ((adj.rotationQuarters % 4) + 4) % 4
if turns != 0 {
    let angle = -CGFloat(turns) * .pi / 2  // ← Negative sign here
    ci = ci.transformed(by: CGAffineTransform(rotationAngle: angle))
    // ...
}
```

**Analysis:**
- `rotationQuarters` is intended to track 90° **clockwise** turns (per comment on line 23).
- The angle is computed as `-turns * π/2`.
- In Core Graphics/Core Image, positive angles rotate **counter-clockwise** and negative angles rotate **clockwise**.
- So `-π/2` should rotate 90° clockwise, which is correct in theory.
- **BUT:** If the sign is backwards (the negative should be positive instead), a single tap would produce counter-clockwise rotation.

**Test:** Change line 72 to `let angle = CGFloat(turns) * .pi / 2` (remove the negative) and verify the rotation direction.

---

### Hypothesis 2: CIImage Inherits Implicit Orientation

**Code location:** `PhotoEditor.swift`, line 63

```swift
guard var ci = CIImage(image: image) else { return image }
```

**Analysis:**
- `UIImage` can have an intrinsic `imageOrientation` property (from EXIF, or from camera capture).
- When you create a `CIImage` from a `UIImage`, does Core Image respect this orientation?
- If the `UIImage` is loaded with orientation (e.g., `.right` or `.left`), the CIImage might already be "rotated" relative to the pixel data.
- Our rotation logic then applies on top of that, causing the combined effect.

**Test:** Print the original image's `.imageOrientation` when loading. If it's not `.up`, that's a clue.

---

### Hypothesis 3: Coordinate System Mismatch in Extent/Origin

**Code location:** `PhotoEditor.swift`, lines 75–76

```swift
ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                          y: -ci.extent.origin.y))
```

**Analysis:**
- After rotation, the image's extent (bounding box) changes and may have a non-zero origin.
- The code re-origins the image so its extent starts at (0, 0).
- However, this logic assumes a specific coordinate system. If there's a mismatch between UIKit (top-left origin) and Core Image (bottom-left origin), the re-origin step might be incorrect.
- This could cause the final image to be rotated or flipped unexpectedly.

**Test:** Log the extent before and after rotation. Check if the re-origin is working as expected.

---

### Hypothesis 4: Interaction Between Flip and Rotation

**Code location:** `PhotoEditor.swift`, lines 66–77

```swift
if adj.flipH { /* ... */ }
// Then rotation applied after
```

**Analysis:**
- The flip is applied **before** rotation.
- If the original image has a non-identity orientation (e.g., from camera capture), the flip might interact unexpectedly with the rotation.
- The order of operations is: flip → rotate → crop → filters.

**Test:** Rotate without flipping, and flip without rotating. Test each independently to isolate.

---

### Hypothesis 5: Save/Load Round-Trip Loses Orientation

**Code location:** `PhotoStore.swift`, lines 109–111 and 122–123

```swift
// Save
func replaceImage(_ image: UIImage, for entry: PhotoEntry) {
    if let data = image.jpegData(compressionQuality: 0.92) {
        try? data.write(to: dir.appendingPathComponent(entry.filename).path)
    }
    // ...
}

// Load
func image(for entry: PhotoEntry) -> UIImage? {
    UIImage(contentsOfFile: dir.appendingPathComponent(entry.filename).path)
}
```

**Analysis:**
- `image.jpegData(compressionQuality:)` bakes the image's pixels into the JPEG, but may or may not preserve the `imageOrientation`.
- When reloading with `UIImage(contentsOfFile:)`, the orientation might be lost or different.
- If the original image had a non-identity orientation (e.g., from iPhone camera), it might be lost in the save/load cycle.

**Test:** Check if the original image's `.imageOrientation` is `.up`. If not, it might be causing issues.

---

## Investigation Plan

### Step 1: Verify the Angle Sign
1. Modify line 72: change `let angle = -CGFloat(turns) * .pi / 2` to `let angle = CGFloat(turns) * .pi / 2`.
2. Build and test: tap rotate once, save, verify the result is 90° clockwise (not counter-clockwise).
3. **Expected outcome:** If this fixes it, the bug is a simple sign inversion.

### Step 2: Check Implicit Orientation
1. In `load()` or `ImagePipeline.apply()`, log the original image's `.imageOrientation`.
2. If it's not `.up`, investigate how it affects the rotation.
3. Consider explicitly normalizing the image to `.up` orientation before applying transformations.

### Step 3: Verify Extent Re-Origining
1. Log `ci.extent` before and after the rotation transform.
2. Verify that the re-origin step is mathematically correct.
3. Manually calculate what the extent should be after a 90° rotation and compare.

### Step 4: Test Flip + Rotate Interaction
1. Test rotation without flip (hold `flipH = false`).
2. Test flip without rotation (hold `rotationQuarters = 0`).
3. If one works but both together fails, the interaction is the culprit.

### Step 5: Save/Load Round-Trip
1. Check if the original loaded image has non-identity orientation.
2. Test saving and reloading an image with no adjustments — verify it round-trips identically.

---

## Recommended First Fix

**Most likely cause:** Angle sign inversion (Hypothesis 1).

**Fix:**
```swift
// Before
let angle = -CGFloat(turns) * .pi / 2

// After
let angle = CGFloat(turns) * .pi / 2
```

**Rationale:**
- The symptom (exactly 90° counter-clockwise when expecting clockwise) is a perfect match for a sign flip.
- This is the simplest fix to test first.
- If the negative was intentional to match Core Image's coordinate system, the bug would have been caught during v0.1 testing; the fact it's appearing now suggests the intent may have been misunderstood.

---

## Fallback: Orientation Normalization

If the sign fix doesn't work, normalize the input image to `.up` orientation before any transformations:

```swift
// At the start of ImagePipeline.apply()
var image = image
if image.imageOrientation != .up {
    // Bake the orientation into pixels, normalize to .up
    let size = image.size
    UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
    image.draw(in: CGRect(origin: .zero, size: size))
    image = UIGraphicsGetImageFromCurrentImageContext() ?? image
    UIGraphicsEndImageContext()
}
guard var ci = CIImage(image: image) else { return image }
```

This ensures all downstream logic works with a canonical `.up` orientation and avoids orientation-related surprises.

---

## Testing Checklist

- [ ] Single 90° rotation (clockwise expected)
- [ ] 180° rotation (two taps)
- [ ] 270° rotation (three taps)
- [ ] 360° rotation (four taps, should match original)
- [ ] Rotation + flip combination
- [ ] Rotation + crop combination
- [ ] Rotation + other adjustments (exposure, etc.) combination
- [ ] Save, close app, reopen gallery, re-edit the rotated photo (verify consistency)

