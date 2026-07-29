# Apollo Cam — Setup Guide (no Mac, jailbroken iPhone)

The app compiles in the cloud on GitHub's free macOS machines; you install the resulting `.ipa` on your jailbroken phone. No Mac ever touches the process.

## 1. Push the project to GitHub (~5 min)
You already know this flow from your website repo.

1. Create a new **private** repo on github.com, e.g. `apollo-cam`.
2. On your PC:
   ```
   cd path/to/ApolloCam
   git init
   git add .
   git commit -m "Apollo Cam v0.1"
   git branch -M main
   git remote add origin https://github.com/YOURNAME/apollo-cam.git
   git push -u origin main
   ```

## 2. Let GitHub build the IPA (~5 min, automatic)
1. The push triggers the workflow in `.github/workflows/build.yml` automatically.
2. On github.com → your repo → **Actions** tab → watch the "Build ApolloCam IPA" run.
3. When it goes green, open the run → **Artifacts** section at the bottom → download **ApolloCam-ipa** (a zip containing `ApolloCam.ipa`).
4. **If it goes red:** open the failed step, copy the error text, paste it back to Claude for a fix. Push the fixed file and it rebuilds automatically.

## 3. Install on your jailbroken iPhone
Pick whichever matches your setup:

**Option A — TrollStore (recommended, permanent install)**
1. If not installed yet: since you're jailbroken, install TrollStore via the "TrollInstallerX" or "TrollHelper" method for your jailbreak (search your jailbreak's community guide — it's a 2-minute install on jailbroken iOS 16).
2. Get `ApolloCam.ipa` onto the phone (AirDrop alternative: upload to iCloud Drive / Filza via SMB / send to yourself).
3. Open the ipa with TrollStore → **Install**. Done — permanent, never expires.

**Option B — AppSync Unified (direct install)**
1. In your package manager (Sileo/Zebra), add the Karen's repo (`cydia.akemi.ai`) and install **AppSync Unified**.
2. Install the ipa with Filza (tap the ipa → install) or `ipainstaller` from terminal.

**Option C — Sideloadly on Windows (no jailbreak tools)**
1. Install Sideloadly on your PC, plug in the phone, sign with a free Apple ID.
2. Note: this route expires after 7 days and needs re-sideloading; A/B don't.

## 4. Add your Anthropic API key (powers the critique coach)
1. Go to **console.anthropic.com** → API keys → create a key, and add ~$5 credit under Billing.
2. In the app: **Settings tab → paste key → Save key.** Stored in the iOS Keychain, only ever sent to api.anthropic.com.
3. Default model is Haiku (fraction of a cent per critique). Switch to Sonnet in Settings for deeper feedback.

## What works (as of v0.90)
- **Camera coach** — a single line of live advice over the preview. On-device guidance by default; turn on Coach and Claude looks at the frame and gives one concrete instruction plus a suggested zoom.
- **Composition guide** — a rule-of-thirds grid over the live preview by default (toggle in Settings → Camera). Pick a specific guide — Auto, rule of thirds, centered, symmetry, leading lines — to draw that guide's shape instead, which turns green when your subject lands on target.
- **Subject detection** — on-device (faces > animals > salient objects), directional guidance ("Move subject right and up"), haptic when aligned. Tap to pick your subject; tap it again to clear.
- **Lighting hints** — too dark / blown-out warnings.
- **Zoom** — 0.5×/1×/2×/3×-style stop buttons taken from the lenses your phone actually has, expanding to a fine slider on demand. Pinch works too.
- **Evaluate** — 5-dimension Claude critique (Composition, Lighting, Color, Focus, Aesthetics) with scores, feedback, and one actionable tip each. Available on single photos or a gallery selection.
- **Editor** — manual tone/colour sliders, rotate, flip, a precise ±45° Straighten slider (with a reference grid), crop (with a thirds grid and centre cross, now inset from the screen edge for easier corner handles), and AI Adjust, which suggests values, a straighten correction, and a crop on the same controls.
- **Learn from pros** — import any photo you admire → "Why does this work?" teacher-mode breakdown.
- **Gallery** — all photos + critiques stored locally on-device, with multi-select (tap or swipe-drag to select a batch) for bulk save / share / evaluate / delete.

## Honest limitations
- "Auto" composition selection is heuristic (subject size/position), not a trained scene classifier.
- Leading lines / frame-within-frame overlays are static guides — the app doesn't yet detect actual lines in your scene.
- The v0.88 zoom work has not been run on a physical phone yet, and the simulator can't exercise it (no multi-lens device, so it falls back to 1×–3×). See `Known Issues.md`.
- The v0.90 Straighten tool fixes in-plane tilt only, not perspective/keystone distortion (converging verticals from tilting the camera up or down at a building) — a genuinely different correction that isn't built yet.
- The v0.90 editor math (straighten's auto-zoom, and its composition with an AI-suggested crop) has not been run on a physical phone yet either. See `Known Issues.md`.
- No accounts/sync — all local (fine while the user is just you).
- Iteration loop is: edit code → push → wait ~5 min for CI → reinstall ipa. Slower than Xcode, but free and Mac-less.

## Fixing build errors
This code was written carefully but has never been compiled (no iOS toolchain outside macOS). Expect 1–3 rounds of small fixes: copy the red error from the Actions log, paste it to Claude, push the corrected file, rebuild.
