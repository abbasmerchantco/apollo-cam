# ApolloCam — Technical Decisions

State as of v0.82, with additions noted (v0.90) where a new decision was made in a later pass. Not a full rewrite for the intervening versions — see `Architecture.md` / `Known Issues.md` / `Roadmap.md` for what shipped in v0.85/v0.88 in the meantime.

## Overview

This document captures key architectural and technology choices made for ApolloCam, the reasoning behind them, and trade-offs accepted.

---

## Stack & Language Choices

### Swift + SwiftUI + Swift Concurrency

**Decision:** Use modern Swift with SwiftUI for the UI layer and async/await for concurrency.

**Reasoning:** SwiftUI provides reactive, declarative UI composition that pairs naturally with real-time camera/vision work. Swift Concurrency (async/await) is the current recommended pattern for structured concurrency on Apple platforms and avoids callback hell in frame-processing loops.

**Alternatives considered:** UIKit (more maturity but imperative, verbose, and camera integration is more boilerplate); React Native or Flutter (loss of native camera APIs and real-time performance).

**Trade-offs:** SwiftUI is still maturing (some edge cases in animations/state management); the team accepts a small number of workarounds (e.g., `DragGesture` for hold-to-compare instead of `onLongPressGesture`) in exchange for cleaner overall architecture.

---

## AI & Vision

### On-Device Vision + Claude API for Coaching/Critique

**Decision:** Use Apple's Vision framework (on-device, real-time) for subject detection and composition guidance; offload detailed critique and AI coaching to Claude API (cloud).

**Reasoning:**
- **On-device vision:** Faces, animals, and salient objects can be detected with zero network latency. Users expect instant guidance while framing. Cloud latency is unacceptable for live coaching.
- **Claude for critique:** Photo evaluation (5-dimensional scoring, narrative feedback, teaching examples) benefits from language depth that on-device models don't offer. The critique happens *after* the photo is taken, so latency is acceptable. Claude's API supports fine-grained reasoning and can be customized with system prompts.

**Alternatives considered:** Full on-device ML (slower iteration, limited accuracy); cloud-only vision (latency defeats live guidance); smaller LLMs for critique (loss of reasoning quality).

**Trade-offs:** Requires Claude API key (small cost per critique, mitigated by Haiku default); users must have network for coaching features; dependency on Anthropic's availability.

### Haiku as Default, Sonnet as Option

**Decision:** Default to Claude Haiku for critiques; allow users to switch to Sonnet in Settings.

**Reasoning:** Haiku is ~90% of Sonnet's quality at a fraction of the cost (~10x cheaper). For a photography coach, quicker feedback with acceptable depth is preferable to slow, deep analysis. Power users can opt into Sonnet for more elaborate critiques.

**Trade-offs:** Some loss of reasoning depth for the default; Sonnet users pay more per critique.

---

## UI & Interaction Design

### Camera Coach Redesign (v0.82): Text Over Overlays

**Decision:** Removed all drawn composition overlays (grids, circles, tracking boxes) and the multi-card info stack. Guidance is now a single line of text with an icon.

**Reasoning:**
- **Clutter reduction:** Every overlay (rule geometry, tracking box, tip cards, scene pills) competed for visual real estate and made the preview feel jittery and noisy.
- **Cognitive load:** Users couldn't focus on framing when bombarded with UI elements. A single line of live coaching (e.g., "Move right and up") is actionable without overwhelming.
- **Performance:** Fewer draw calls per frame; no `GeometryReader` over the entire preview.

**Alternatives considered:** Smarter layering/z-order (still cluttered); hidden overlays with a "show guides" toggle (hidden guidance is less useful during live framing).

**Trade-offs:** Lost visual feedback for composition rules (users can no longer see the rule-of-thirds grid). Mitigated by text hints ("You're in rule of thirds") and the assumption that experienced photographers internalize rules without visual props. New users may need to reference the manual once.

### Subject Selection: Brief Fading Ring Instead of Persistent Box

**Decision:** Tapping to select a subject shows a brief fading ring; the box disappears after ~0.5s. No persistent tracking overlay.

**Reasoning:** The fading ring gives instant tactile feedback ("I tapped the subject") without leaving a semi-transparent box that blocks the live preview and grows too large under certain conditions. Keeps the preview clean while confirming intent.

**Trade-offs:** Subtle feedback; users who expect a persistent indicator may tap again thinking the first tap didn't register. Addressed by haptic feedback and documentation.

---

## Photo Editing

### Non-Destructive Edit Pipeline

**Decision:** `EditAdjustments` (color, tone, orientation, crop) is separate from the original image. `ImagePipeline.apply()` is a pure function that composites original → orientation → crop → adjustments → output.

**Reasoning:**
- **Reversibility:** Users can undo/reset any adjustment without losing data. The original is always recoverable.
- **Performance:** Adjustments don't write back to disk; only the final export does. Preview and final output use the same pipeline, so WYSIWYG is guaranteed.
- **Composability:** Each adjustment is independent; order of operations is explicit and testable.

**Alternatives considered:** Destructive editing (faster on very old devices, but violates user expectations); separate pipelines for preview and export (preview-export mismatch bugs).

**Trade-offs:** Memory overhead (proxy image in RAM); slightly slower final export (recomputing from original). Acceptable for a modern iPhone with sufficient RAM.

### Crop as a Distinct Mode, Not a Slider

**Decision:** Crop has its own UI state and mode. Entering crop shows an uncropped version of the image with a draggable rect overlay; exiting crop applies the crop or discards it.

**Reasoning:**
- **Clarity:** Users understand the before/after clearly. No ambiguity about what "cropping at 70%" means.
- **Precision:** A draggable rect with corner handles gives fine control. Sliders feel imprecise for framing adjustments.
- **Non-destructive:** Crop state is tracked independently, so AI suggestions can preserve a user's existing crop.

**Trade-offs:** More UI state to manage; slightly more code. Worth the clarity.

### Straighten as Rotate + Auto-Zoom-to-Cover, Not Perspective/Keystone Correction (v0.90)

**Decision:** The Straighten tool (and AI Adjust's matching suggestion) is a single continuous in-plane rotation (±45°) about the image center, with just enough zoom to eliminate the empty corner wedges the rotation exposes. It does not attempt perspective/keystone correction (fixing converging verticals caused by tilting the camera up or down at a building, for example).

**Reasoning:** In-plane rotation is a 2D affine transform Core Image already does cheaply and exactly, and it's what "the horizon/a building edge is tilted in the frame" actually needs. True keystone correction is a 3D perspective warp — a materially different, more complex operation (four independently-draggable corner handles or a vertical-vanishing-point estimate, non-affine image resampling) that solves a different symptom (converging verticals from camera angle, not in-plane tilt). Building both at once would have doubled the scope of a tool meant to be a lightweight companion to the 90° rotate button.

**Alternatives considered:** Full keystone/perspective correction tool (real capability gap for architecture shooters, but significantly more UI and math — a candidate for its own future pass, not a straighten slider); leaving empty corners after rotation and requiring a manual follow-up crop (simpler code, worse UX — Photos/Snapseed's auto-zoom-to-cover behavior is what users expect from a "straighten" control).

**Trade-offs:** A photo whose problem is genuinely converging verticals (not just an off-level horizon) will not look fully corrected after Straighten — rotating it can make the tilt read differently but can't remove the perspective convergence itself. Worth flagging to users only if this turns out to be a common request in practice; not addressed now.

### Backward-Compatible Custom Decoding for `EditAdjustments` (v0.90)

**Decision:** `EditAdjustments` implements a custom `Decodable.init(from:)` that reads every field via `decodeIfPresent(...) ?? default`, rather than relying on Swift's synthesized `Codable` conformance.

**Reasoning:** Synthesized `Decodable` requires every stored property's key to be present in the source JSON regardless of the property's own default value. `PhotoStore.load()` decodes the entire persisted `[PhotoEntry]` array in one call and swallows failure with `try?` (a saved-locally, no-backend design — see "Local-Only Storage" below), so a single missing key anywhere in the array fails the *whole* decode, and the app behaves as if the gallery were empty. Since this struct is expected to keep gaining fields as editing tools are added (straighten in v0.90; more will follow), a decode strategy that breaks on every future field addition is a standing risk to real user data, not a one-time cost.

**Alternatives considered:** Leave synthesized `Codable` and remember to version-migrate on every future field addition (relies on remembering, under exactly the conditions — a fast feature addition — where it's easiest to forget); wrap the array decode to decode entries individually and drop only the failing ones (would at least localize data loss to the changed entries rather than the whole array, but doesn't address the root cause and adds its own complexity to `PhotoStore`).

**Trade-offs:** A few more lines of boilerplate whenever a field is added or renamed (must remember to add the corresponding `CodingKeys` case and `decodeIfPresent` line) — a small, contained cost in exchange for removing a category of silent data loss.

---

## Architecture & State Management

### Minimal State, Unidirectional Data Flow

**Decision:** `CameraScreen` holds a small set of mutable state (`selectedPoint`, `coachingChip`, etc.); `PhotoEditor` owns `EditAdjustments` and `rendered`. Services (`SubjectDetector`, `AdviceService`) compute and emit updates; views react to state changes.

**Reasoning:** Unidirectional flow (model → view) prevents state sync bugs. Camera and editor are decoupled; adding a new editing tool doesn't require camera changes.

**Alternatives considered:** Fully reactive/Redux-style architecture (overkill for a two-screen app); deeply nested state (harder to reason about).

**Trade-offs:** Some state duplication (e.g., `GuidanceEngine` output is computed but partially unconsumed); justifiable for clarity.

---

## Development & Deployment

### GitHub Actions CI + Jailbroken iPhone, No Mac Required

**Decision:** Build the app on GitHub's free macOS runners; download the `.ipa` and install via TrollStore on a jailbroken device.

**Reasoning:**
- **No Mac dependency:** Developers can iterate from a PC or Linux machine. Lowers friction for contributors.
- **Reproducible builds:** CI environment is ephemeral and version-controlled (`.github/workflows/build.yml`).
- **Cost:** GitHub Actions are free for public repos; Netlify builds the website the same way.

**Alternatives considered:** Xcode + fastlane locally (requires Mac); TestFlight (requires Apple Developer account and ~48h review time per build).

**Trade-offs:** 5-minute build time vs instant feedback from Xcode; jailbreak requirement (not mainstream, but acceptable for a personal project and early development); no App Store path (acceptable for MVP).

### Keychain for API Key Storage

**Decision:** The Claude API key is stored in iOS Keychain, never in UserDefaults or files.

**Reasoning:** Keychain is the OS-level secure storage for credentials. Keys at rest are encrypted; access requires device unlock or app authorization.

**Alternatives considered:** UserDefaults (easy but unencrypted); manual encryption (adds complexity).

**Trade-offs:** None significant; Keychain is the standard.

---

## Local-Only Storage (MVP)

**Decision:** All photos, critiques, and settings are stored locally on the device. No cloud sync, no accounts.

**Reasoning:**
- **Privacy:** User data never leaves the device.
- **Simplicity:** No backend to maintain; no user management, auth, or database.
- **Launch speed:** MVP ships with zero backend infrastructure.

**Alternatives considered:** iCloud sync (requires Apple account integration); custom backend (maintenance burden).

**Trade-offs:** Data is lost if the app is uninstalled or the device is reset. Not acceptable long-term; documented as a future feature (see `Roadmap.md`).

---

## Known Technical Debt

See `Known Issues.md` for active bugs (e.g., rotate-save off-by-one).

Areas acknowledged for future work:
- Trained scene classifier (replacing heuristic "auto" rule selection).
- Tilt/level indicator (requires CoreMotion integration).
- UI for scene override (currently always automatic).
- Cloud sync and accounts.

---

## Review & Update Cadence

This document is updated alongside `Architecture.md` after significant technical changes (new features, major refactors, or decisions to revisit earlier choices).

Last reviewed: v0.82 camera redesign and photo editor fixes, with v0.90 additions for the Straighten tool and the `EditAdjustments` decoding fix. The v0.85/v0.88 gap in this document (zoom rework, camera-screen composition-guide fix, gallery multi-select) was not backfilled — see `Architecture.md`, `Known Issues.md`, and `Roadmap.md` for those.
