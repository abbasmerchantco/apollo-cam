# ApolloCam — Release Notes

## v0.85

**Photo editor**
- Fixed: saving an edited photo came back rotated 90° the wrong way. The same bug was behind the older "one 90° turn fewer than you tapped" report — the two were always the same fault. Root cause: Core Image works on raw pixels and ignores the orientation flag a camera photo carries, so every save was transformed in sensor space. Previews escaped it because they are re-drawn through a path that does honour orientation, which is why previews always looked right and only saves were wrong.
- Fixed: AI Adjust silently discarded a rotate or flip you had already applied.

**AI Adjust**
- AI Adjust now suggests a crop as well as tone and colour. Claude looks at the composition and subject placement and re-frames the shot when the framing is genuinely working against the photo — most photos still come back uncropped, the same restraint the colour values already follow. The suggested crop lands on the crop tool like any other value, so you can drag it from there or Reset it.
- The suggested crop is remembered per photo alongside the other AI values, so Reset → AI Adjust reapplies it for free. It stays correct even if you rotate the photo after asking for the suggestion.

## v0.82

**Camera screen redesign.** Reworked the live camera screen toward a simpler, calmer "Camera Coach"-style interface: removed the drawn composition-rule geometry (grids, circles, lines) and the subject-detection tracking box from the live preview, replaced the rule-name pill / tip stack / scene-pill strip / AI-partner card with a single line of live coaching text, simplified the top bar to two icon buttons, and trimmed the manual composition-rule picker down to a short, recognizable set (Auto, Rule of thirds, Centered, Symmetry, Leading lines). Tapping to select a subject now shows a brief fading ring instead of a persistent box; subject detection and AI coaching still work the same as before under the hood.

**Photo editor fixes and additions:**
- Fixed: holding the photo to compare against the original would flash briefly and immediately snap back to the edited version instead of staying held.
- Fixed: the photo displayed at a smaller size after an AI adjustment note appeared, versus before editing.
- Added: a crop tool (drag corner handles to resize, drag inside to move, with Cancel/Reset/Apply).

**Known limitation carried forward:** the rotate tool can occasionally save an image with one fewer 90° turn than was applied. Still investigating — see `Known Issues.md`. *(Fixed in v0.85.)*
