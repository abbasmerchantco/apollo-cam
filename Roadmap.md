# ApolloCam — Roadmap

State as of v0.88.

## Product direction

The organising goal, stated directly: **make it much easier for a beginner to take a better photo than they would have taken on their own.** Claude's role is a photographer friend standing at your shoulder — coaching while you shoot, then helping you edit. Features earn their place by removing a decision the user doesn't know how to make, not by adding a control they now have to understand.

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
- **Real-world test the v0.88 zoom rework on device** — the display/device zoom mapping depends on `virtualDeviceSwitchOverVideoZoomFactors`, which the simulator doesn't supply. Check the derived stops against the stock camera app on each phone available, and check that capture at 0.5× and at a telephoto stop produces the resolution and `ShotInfo.zoom` you'd expect. See `Known Issues.md`.
- **Judge the AI-suggested zoom in practice** — same open question as the AI crop: the prompt is biased toward tighter framing and real lens stops, and only real shooting says whether that's right.
- **Real-world test the v0.85 editor changes** — particularly the rotation fix across the full matrix (rotate, rotate+flip, rotate+crop, save/reopen/re-edit), since the bug hid behind a correct-looking preview for several versions and the fix has not yet been run on device.
- **Judge the AI crop suggestions in practice** — the prompt is deliberately biased toward returning no crop. If it turns out to be too eager or too timid on real shots, that threshold is the thing to tune before anything else.
- Consider a tilt/level indicator (a subtle horizon-line guide that only appears when the phone is meaningfully off-level) — discussed as part of the camera redesign mockup but not built; would need CoreMotion, which isn't wired into the app yet.
- ~~Revisit `SETUP.md`'s "What works in this MVP" section~~ — done in v0.88.

## Later / under consideration
- Trained scene classifier to replace the current heuristic "auto" composition-rule selection.
- Accounts/sync (currently all-local, single-device).
