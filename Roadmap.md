# ApolloCam — Roadmap

State as of v0.90.

## Product direction

The organising goal, stated directly: **make it much easier for a beginner to take a better photo than they would have taken on their own.** Claude's role is a photographer friend standing at your shoulder — coaching while you shoot, then helping you edit. Features earn their place by removing a decision the user doesn't know how to make, not by adding a control they now have to understand.

## Recently shipped (v0.90)
- Editor: crop area inset 22pt from the container edge so corner handles aren't fighting the screen bezel.
- Editor: new Straighten tool — a continuous ±45° fine-rotation slider (auto-zooms to cover, no empty corners), alongside the existing 90° rotate button. Shows a thirds/centre reference grid while active, since manual straighten previously had no visual reference to judge level against.
- AI Adjust: now also proposes a straighten correction, and looks for it deliberately — any off-level vertical or horizontal reference (building edges, doorframes, poles, a horizon), not only an obvious tilted horizon. The crop suggestion now also considers symmetry/centering (not just dead space or an off-balance subject), and accounts for straighten's auto-zoom when placing itself.
- Gallery: swipe-to-select — drag across thumbnails in selection mode to mass-select (or mass-deselect) them, mirroring Photos.
- Fixed a latent data-loss risk: `EditAdjustments` now decodes with per-field fallbacks instead of synthesized `Decodable`, so adding `straighten` (or any future field) can't silently empty the saved gallery index on an older photo library. See `Known Issues.md`.

## Recently shipped (v0.88)
- Camera: composition overlay restored (fixing a guide that had drawn nothing since v0.82), thirds grid on by default with a Settings toggle.
- Camera: zoom rework — real optical 0.5× via the multi-lens virtual device, stock-style stop buttons derived from the phone's actual lenses, fine slider on demand.
- Camera: Coach pulls back to the widest lens to see the whole scene and hands back a one-tap suggested zoom.
- Gallery: multi-select with bulk save / share / evaluate / delete.
- Editor: thirds grid and centre cross inside the crop rectangle.

## Recently shipped (v0.85)
- Photo editor: fixed the rotate/save bug (orientation metadata was being dropped before the Core Image transforms — see `Known Issues.md`), and stopped AI Adjust from wiping an applied rotate/flip.
- AI Adjust: now suggests a crop alongside the tone and colour values, cached per photo like the rest of the suggestion.

## Recently shipped (v0.82)
- Photo editor: fixed hold-to-compare, fixed image-resize-on-edit, added a crop tool.
- Camera screen: redesigned to a "Camera Coach"-style minimal UI — no drawn composition-rule geometry or subject tracking box on the live preview, guidance/AI-partner/scene folded into a single coaching line, curated rule picker, icon-only top bar.

## Near-term
- **Real-world test the v0.90 straighten/crop math on device** — the auto-zoom-to-cover scale and the crop+straighten composition (`ImagePipeline.orientedCropRect`) were derived and sanity-checked analytically, not verified against a real rendered photo. Test with a genuinely off-vertical shot (a leaning building works well), at several angles, with and without an accompanying AI crop.
- **Judge the broadened AI Adjust prompt in practice** — v0.90 asks it to actively look for off-level verticals/horizontals rather than defaulting to 0, and to consider a symmetry/centering crop alongside straighten. Whether it now reliably catches subtle tilts (the original prompt missed a real slightly-off building), and whether the crop-for-symmetry addition helps or just adds noise, is only answerable by shooting a variety of real photos through it.
- **Real-world test the v0.88 zoom rework on device** — the display/device zoom mapping depends on `virtualDeviceSwitchOverVideoZoomFactors`, which the simulator doesn't supply. Check the derived stops against the stock camera app on each phone available, and check that capture at 0.5× and at a telephoto stop produces the resolution and `ShotInfo.zoom` you'd expect. See `Known Issues.md`.
- **Judge the AI-suggested zoom in practice** — same open question as the AI crop: the prompt is biased toward tighter framing and real lens stops, and only real shooting says whether that's right.
- **Real-world test the v0.85 editor changes** — particularly the rotation fix across the full matrix (rotate, rotate+flip, rotate+crop, save/reopen/re-edit), since the bug hid behind a correct-looking preview for several versions and the fix has not yet been run on device.
- **Judge the AI crop suggestions in practice** — the prompt is deliberately biased toward returning no crop. If it turns out to be too eager or too timid on real shots, that threshold is the thing to tune before anything else.
- Consider a tilt/level indicator (a subtle horizon-line guide that only appears when the phone is meaningfully off-level) — discussed as part of the camera redesign mockup but not built; would need CoreMotion, which isn't wired into the app yet. Distinct from v0.90's editor Straighten tool: this would catch the tilt *while shooting*, before the shot is taken, rather than correcting it afterward.
- ~~Revisit `SETUP.md`'s "What works in this MVP" section~~ — done in v0.88.

## Later / under consideration
- Trained scene classifier to replace the current heuristic "auto" composition-rule selection.
- Accounts/sync (currently all-local, single-device).
