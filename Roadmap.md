# ApolloCam — Roadmap

State as of v0.82.

## Recently shipped (v0.82)
- Photo editor: fixed hold-to-compare, fixed image-resize-on-edit, added a crop tool.
- Camera screen: redesigned to a "Camera Coach"-style minimal UI — no drawn composition-rule geometry or subject tracking box on the live preview, guidance/AI-partner/scene folded into a single coaching line, curated rule picker, icon-only top bar.

## Near-term
- Root-cause and fix the rotate-tool off-by-one bug (see `Known Issues.md`) — needs reproduction with logging before a fix is attempted.
- Consider a tilt/level indicator (a subtle horizon-line guide that only appears when the phone is meaningfully off-level) — discussed as part of the camera redesign mockup but not built; would need CoreMotion, which isn't wired into the app yet.
- Revisit `SETUP.md`'s "What works in this MVP" section, which still describes the old drawn-overlay composition guide and full 14-rule list — now stale relative to the redesigned camera screen.

## Later / under consideration
- Trained scene classifier to replace the current heuristic "auto" composition-rule selection.
- Accounts/sync (currently all-local, single-device).
