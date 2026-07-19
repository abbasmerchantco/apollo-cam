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

## What works in this MVP
- **Live composition guide** — auto-picks a rule from the scene (or choose manually): rule of thirds, golden ratio, centered circle, diagonal, symmetry, leading lines, frame-within-frame, foreground interest, layering.
- **Subject detection** — on-device (faces > animals > salient objects), tracked bounding box, directional guidance ("Move subject right and up"), haptic + green lines when aligned.
- **Lighting hints** — too dark / blown-out warnings.
- **Zoom presets** — 1× / 2× / 5×.
- **Evaluate** — 5-dimension Claude critique (Composition, Lighting, Color, Focus, Aesthetics) with scores, feedback, and one actionable tip each.
- **Learn from pros** — import any photo you admire → "Why does this work?" teacher-mode breakdown.
- **Gallery** — all photos + critiques stored locally on-device.

## Honest limitations (MVP)
- "Auto" composition selection is heuristic (subject size/position), not a trained scene classifier.
- Leading lines / frame-within-frame overlays are static guides — the app doesn't yet detect actual lines in your scene.
- No accounts/sync — all local (fine while the user is just you).
- Iteration loop is: edit code → push → wait ~5 min for CI → reinstall ipa. Slower than Xcode, but free and Mac-less.

## Fixing build errors
This code was written carefully but has never been compiled (no iOS toolchain outside macOS). Expect 1–3 rounds of small fixes: copy the red error from the Actions log, paste it to Claude, push the corrected file, rebuild.
