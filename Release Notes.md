# ApolloCam — Release Notes

## v0.88

The theme of this release is making the app usable by someone who doesn't know what makes a photo good. Every change below exists to move a decision off the user and onto the app.

**Camera — composition guide now actually draws something**
- Fixed: turning on a composition guide showed no overlay at all. The guide sheet has been changing only the coaching text since v0.82, when the drawn geometry was removed from the preview — the picker was left behind pointing at nothing.
- A rule-of-thirds grid is now shown over the live preview by default, drawn as thin viewfinder furniture rather than the loud overlay v0.82 removed. Picking a specific guide (Centered, Symmetry, Leading lines) replaces the grid with that guide's shape in the brighter treatment, and it turns green when your subject lands on target.
- The grid can be turned off in Settings → Camera.

**Camera — zoom**
- Replaced the always-on zoom slider with 0.5×/1×/2×/3× buttons. The exact stops now come from the lenses your phone actually has, so they match your phone's own camera app — a Pro shows 0.5/1/2/5, a single-lens phone shows 1/2/3.
- 0.5× is a real optical ultra-wide, not a crop. The app previously only opened the wide-angle camera, which physically cannot go below 1×.
- Tap the highlighted button to unfold a fine slider for framing between the stops. Pinch-to-zoom still works everywhere.

**Camera — Coach**
- Turning Coach on now pulls the camera back to its widest lens so Claude can see the whole scene. It can't tell you there's a better angle to your left if your left isn't in the frame.
- Claude now returns a suggested zoom with its advice, offered as a one-tap gold button next to the coaching line. Turning Coach off returns you to the framing you had before.

**Gallery — multi-select**
- New Select button. Tap photos to pick a batch, then Save to your library, Share, Evaluate, or Delete them together. All / None in the top left.
- Bulk Evaluate runs one photo at a time and skips anything already evaluated, so a batch never spends more of the daily token budget than it needs to. It stops cleanly and tells you if you run out partway through.

**Editor — crop grid**
- The crop tool now draws a rule-of-thirds grid plus a dashed centre cross inside the crop rectangle, so you can line up a symmetrical shot against the true middle. Thirds alone can't tell you where centre is.

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
