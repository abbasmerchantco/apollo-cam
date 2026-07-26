# ApolloCam — Release Notes

## v0.82

**Camera screen redesign.** Reworked the live camera screen toward a simpler, calmer "Camera Coach"-style interface: removed the drawn composition-rule geometry (grids, circles, lines) and the subject-detection tracking box from the live preview, replaced the rule-name pill / tip stack / scene-pill strip / AI-partner card with a single line of live coaching text, simplified the top bar to two icon buttons, and trimmed the manual composition-rule picker down to a short, recognizable set (Auto, Rule of thirds, Centered, Symmetry, Leading lines). Tapping to select a subject now shows a brief fading ring instead of a persistent box; subject detection and AI coaching still work the same as before under the hood.

**Photo editor fixes and additions:**
- Fixed: holding the photo to compare against the original would flash briefly and immediately snap back to the edited version instead of staying held.
- Fixed: the photo displayed at a smaller size after an AI adjustment note appeared, versus before editing.
- Added: a crop tool (drag corner handles to resize, drag inside to move, with Cancel/Reset/Apply).

**Known limitation carried forward:** the rotate tool can occasionally save an image with one fewer 90° turn than was applied. Still investigating — see `Known Issues.md`.
