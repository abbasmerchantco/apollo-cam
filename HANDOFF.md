# ApolloCam Handoff — AI Crops & Rotation Fix

## 1. AI Crop Suggestions Feature

**Status:** Scoped, ready to implement  
**Priority:** Near-term  
**Effort:** Medium

### What
Extend AI adjustment suggestions to include crop recommendations. Claude analyzes composition and subject position, suggests optimal crop rect. User can tap to apply alongside other adjustments (exposure, color, tone).

### Implementation
- **Extend `AdjustService`** to generate crop suggestions via Claude API (new output field: `suggestedCrop: CGRect?` with reasoning)
- **Update `PhotoEditorView`** to display crop in adjustment suggestions list (similar to current exposure/color/tone items)
- **Preserve existing crop** when accepting other AI adjustments (already done in `aiAdjust()` line 709)
- **Order of operations:** Orientation → Crop → Filters (unchanged; crop is already in this position)

### Test
- Tap AI adjust on a landscape photo → crop suggestion appears
- Accept crop → preview updates immediately
- Combine crop + exposure suggestion → both applied
- Reject crop, try again → reuses cached suggestion
- Save → full-res output has crop baked in

### Files
- `AdjustService.swift` – add crop suggestion logic
- `PhotoEditor.swift` – add UI for crop suggestion display
- `Technical Decisions.md` – document decision to include crop as AI suggestion

**See:** `Roadmap.md` (near-term section)

---

## 2. Rotation Bug Fix

**Status:** Root cause identified, fix ready to test  
**Priority:** High (confirmed regression)  
**Effort:** Low (likely one-line fix)

### What
Saving an edited photo rotates it 90° counter-clockwise when user expects clockwise. Root cause: angle sign inversion in rotation transform.

### Fix (Primary)
**File:** `PhotoEditor.swift`, line 72  
**Change:**
```swift
// Before
let angle = -CGFloat(turns) * .pi / 2

// After
let angle = CGFloat(turns) * .pi / 2
```

**Reasoning:** Negative angle should rotate clockwise in Core Image, but the symptom (exactly 90° counter-clockwise) suggests the sign is backwards.

### Test (Critical)
- Single tap rotate → saved image is 90° clockwise ✓
- Double tap → 180° ✓
- Triple tap → 270° clockwise ✓
- Quad tap → same as original ✓
- Rotate + flip → both applied correctly ✓
- Rotate + crop → both in final output ✓

### Fallback Fix (If Primary Doesn't Work)
If angle sign change doesn't fix it, the issue is likely UIImage orientation metadata. Normalize to `.up` before transforms:

```swift
// At start of ImagePipeline.apply()
var image = image
if image.imageOrientation != .up {
    let size = image.size
    UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
    image.draw(in: CGRect(origin: .zero, size: size))
    image = UIGraphicsGetImageFromCurrentImageContext() ?? image
    UIGraphicsEndImageContext()
}
guard var ci = CIImage(image: image) else { return image }
```

### Files
- `PhotoEditor.swift` – fix angle calculation
- `Known Issues.md` – update status (fixed)
- `Roadmap.md` – remove from near-term

**See:** `Rotation Bug - Investigation Scope.md` (full investigation details, other hypotheses, testing checklist)

---

## Next Steps
1. **Start with rotation fix** (one line, high confidence)
2. **Verify all rotation tests pass**
3. **Then implement AI crop suggestions** (depends on clean rotation behavior)
4. **Update docs** once fixes ship

