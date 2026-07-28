# ApolloCam — Roadmap

State as of v0.85.

## Recently shipped (v0.85)
- Photo editor: fixed the rotate/save bug (orientation metadata was being dropped before the Core Image transforms — see `Known Issues.md`), and stopped AI Adjust from wiping an applied rotate/flip.
- AI Adjust: now suggests a crop alongside the tone and colour values, cached per photo like the rest of the suggestion.

## Recently shipped (v0.82)
- Photo editor: fixed hold-to-compare, fixed image-resize-on-edit, added a crop tool.
- Camera screen: redesigned to a "Camera Coach"-style minimal UI — no drawn composition-rule geometry or subject tracking box on the live preview, guidance/AI-partner/scene folded into a single coaching line, curated rule picker, icon-only top bar.

## Near-term
- **Real-world test the v0.85 editor changes** — particularly the rotation fix across the full matrix (rotate, rotate+flip, rotate+crop, save/reopen/re-edit), since the bug hid behind a correct-looking preview for several versions and the fix has not yet been run on device.
- **Judge the AI crop suggestions in practice** — the prompt is deliberately biased toward returning no crop. If it turns out to be too eager or too timid on real shots, that threshold is the thing to tune before anything else.
- Consider a tilt/level indicator (a subtle horizon-line guide that only appears when the phone is meaningfully off-level) — discussed as part of the camera redesign mockup but not built; would need CoreMotion, which isn't wired into the app yet.
- Revisit `SETUP.md`'s "What works in this MVP" section, which still describes the old drawn-overlay composition guide and full 14-rule list — now stale relative to the redesigned camera screen.

## Later / under consideration
- Trained scene classifier to replace the current heuristic "auto" composition-rule selection.
- Accounts/sync (currently all-local, single-device).
