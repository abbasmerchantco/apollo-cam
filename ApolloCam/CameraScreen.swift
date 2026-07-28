import SwiftUI
import Combine

struct CameraScreen: View {
    @StateObject private var camera = CameraController()
    @StateObject private var detector = SubjectDetector()
    @ObservedObject private var tokenManager = TokenManager.shared

    // Composition
    @State private var selectedRule: CompositionRule? = nil   // nil = auto
    @State private var sceneOverride: SceneKind? = nil        // nil = auto-detect
    @State private var guidance = Guidance(message: "Point at your subject", tip: nil, tips: [],
                                           aligned: false, suggestedRule: .ruleOfThirds,
                                           ruleFromModel: false, scene: .general,
                                           sceneFromUser: false, focusPoint: nil)
    @State private var wasAligned = false
    @State private var showRulePicker = false

    // Capture review
    @State private var reviewEntry: PhotoEntry?

    // Tap-to-select feedback — a brief pulse at the tap point instead of a
    // persistent tracking box.
    @State private var tapPulseAt: CGPoint?
    @State private var tapPulseID = UUID()

    // Sheets
    @State private var showGallery = false
    @State private var showSettings = false

    // Overlay
    @AppStorage("showCompositionGrid") private var showGrid = true

    // Zoom
    @State private var pinchStartZoom: CGFloat = 1.0
    @State private var zoomExpanded = false
    /// Where the user was framed before Coach pulled back to the wide view.
    @State private var zoomBeforeCoach: CGFloat?

    // AI Partner
    @State private var partnerOn = false
    @State private var partnerTip: CoachTip?
    @State private var partnerLoading = false
    @State private var partnerError: String?
    @State private var stillSince: Date?
    @State private var lastTipAt = Date.distantPast
    private let heartbeat = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)
    private let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)

    /// Any sheet covering the camera means we should stop capturing entirely.
    private var anySheetPresented: Bool {
        showGallery || showSettings || showRulePicker || reviewEntry != nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.permissionDenied {
                    permissionView
                } else {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    let pt = CGPoint(x: value.location.x / geo.size.width,
                                                     y: value.location.y / geo.size.height)
                                    // No visible "clear" button anymore, so tapping
                                    // near the current selection clears it instead
                                    // of re-selecting the same spot.
                                    if let current = detector.selectedPoint,
                                       hypot(current.x - pt.x, current.y - pt.y) < 0.05 {
                                        detector.clearSelection()
                                    } else {
                                        detector.select(at: pt)
                                    }
                                    Haptics.tap()

                                    let id = UUID()
                                    tapPulseID = id
                                    tapPulseAt = value.location
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        if tapPulseID == id { tapPulseAt = nil }
                                    }
                                }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { scale in
                                    camera.setZoom(pinchStartZoom * scale)
                                }
                                .onEnded { _ in
                                    pinchStartZoom = camera.zoomFactor
                                }
                        )

                    if showGrid {
                        // In reference mode every input is held constant, so SwiftUI
                        // diffs the overlay as unchanged and never redraws it. Feeding
                        // it `guidance` would re-run the Path ~4×/second for a grid
                        // whose geometry cannot change — wasted work on the one screen
                        // where the frame budget actually matters.
                        CompositionOverlay(rule: overlayRule,
                                           aligned: overlayStyle == .guide && guidance.aligned,
                                           style: overlayStyle,
                                           focusPoint: overlayStyle == .guide ? guidance.focusPoint : nil)
                            .ignoresSafeArea()
                    }

                    if let pt = tapPulseAt {
                        TapPulse(color: cyan)
                            .position(pt)
                            .allowsHitTesting(false)
                            .id(tapPulseID)
                    }

                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        coachingChip
                        zoomControl
                        bottomBar
                    }
                }
            }
            .onAppear {
                camera.configure()
                camera.onFrame = { buffer in detector.analyze(buffer) }
                pinchStartZoom = camera.zoomFactor
            }
            .onDisappear { camera.stop() }
            .onChange(of: anySheetPresented) { covered in
                if covered {
                    // Sheet came up: stop the session, drop the subject lock, silence the coach.
                    camera.pause()
                    detector.clearSelection()
                    stillSince = nil
                    wasAligned = false
                } else {
                    camera.resume()
                }
            }
            .onReceive(detector.$subject) { _ in
                guard !camera.isPaused else { return }
                let g = GuidanceEngine.evaluate(
                    subject: detector.subject,
                    personCount: detector.personCount,
                    modelRule: detector.modelRule,
                    rule: selectedRule,
                    sceneOverride: sceneOverride,
                    brightness: detector.brightness,
                    viewSize: geo.size)
                if g.aligned && !wasAligned { Haptics.alignedPing() }
                wasAligned = g.aligned
                // No withAnimation here: this fires ~4x/second and animating the
                // whole tree meant every control below was mid-flight during a
                // tap. The tip block animates its own card changes locally.
                guidance = g
            }
            .onReceive(heartbeat) { _ in partnerHeartbeat() }
        }
        .sheet(isPresented: $showRulePicker) { rulePicker }
        .sheet(isPresented: $showGallery) { GalleryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $reviewEntry) { entry in
            CaptureReviewView(entry: entry)
        }
    }

    // MARK: - Tap feedback

    /// A brief ring at the tap point, standing in for the old persistent
    /// tracking box — subject selection is still tracked and still steers
    /// the coaching text, it's just not drawn on screen anymore.
    private struct TapPulse: View {
        let color: Color
        @State private var animate = false

        var body: some View {
            Circle()
                .stroke(color, lineWidth: 2)
                .frame(width: 46, height: 46)
                .scaleEffect(animate ? 1.4 : 0.6)
                .opacity(animate ? 0 : 0.9)
                .onAppear {
                    withAnimation(.easeOut(duration: 0.5)) { animate = true }
                }
        }
    }

    // MARK: - Composition overlay

    /// Which geometry is drawn over the preview.
    ///
    /// Auto mode is deliberately pinned to a plain thirds grid rather than following
    /// `guidance.suggestedRule`. That value re-evaluates roughly four times a second,
    /// so tracking it would swap the whole overlay — circles to diagonals to
    /// triangles — under the user's eye while they were still framing the shot.
    /// A grid that stays put is the useful thing; the rule that's actually being
    /// coached is already communicated in words by the coaching line.
    private var overlayRule: CompositionRule { selectedRule ?? .ruleOfThirds }

    /// A rule the user picked on purpose earns the loud treatment; the always-on
    /// default stays as quiet as viewfinder furniture.
    private var overlayStyle: CompositionOverlay.Style {
        selectedRule == nil ? .reference : .guide
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button { showRulePicker = true } label: {
                Image(systemName: guidance.suggestedRule.icon)
                    .font(.system(size: 15))
                    .foregroundColor(.white)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .padding(9)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: - Coaching chip

    /// One calm line of live advice, replacing the old rule-name pill, the
    /// three-card tip stack, the scene pill strip, and the separate AI
    /// partner card. When AI Coach is off this shows the instant, on-device
    /// guidance text; when it's on, a fresh AI tip (or its loading/error
    /// state) takes over the same line instead of opening a second card.
    private var coachText: String {
        if partnerOn {
            if let tip = partnerTip { return tip.advice }
            if let err = partnerError { return err }
            if partnerLoading { return "Coach is looking…" }
        }
        return guidance.message
    }

    private var coachIcon: String {
        if partnerOn {
            if let tip = partnerTip { return sanitizedIcon(tip.icon) }
            if partnerError != nil { return "exclamationmark.triangle" }
            if partnerLoading { return "sparkles" }
        }
        return guidance.aligned ? "checkmark.circle.fill" : "scope"
    }

    private var coachingChip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: coachIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(!partnerOn && guidance.aligned ? .green : cyan)
                Text(coachText)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())

            zoomSuggestionChip
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: coachText)
        .animation(.spring(duration: 0.3), value: suggestedZoom)
    }

    /// The zoom Claude thinks this shot wants, if it's meaningfully different from
    /// where the user is now. Coach shoots from the widest lens so it can see the
    /// whole scene, which means "how far in should I actually be?" is a question it
    /// is uniquely placed to answer — and one beginners rarely think to ask.
    private var suggestedZoom: CGFloat? {
        guard partnerOn, let raw = partnerTip?.suggestedZoom else { return nil }
        let target = min(max(CGFloat(raw), camera.minZoom), camera.maxZoom)
        // Ignore nudges too small to be worth a tap.
        guard abs(target - camera.zoomFactor) > max(0.12, camera.zoomFactor * 0.12) else { return nil }
        return target
    }

    private var zoomSuggestionChip: some View {
        Group {
            if let target = suggestedZoom {
                Button {
                    camera.setZoom(target, animated: true)
                    pinchStartZoom = target
                    Haptics.tap()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: target > camera.zoomFactor ? "plus.magnifyingglass" : "minus.magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(zoomLabel(target))×")
                            .font(.caption2.weight(.bold).monospacedDigit())
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(gold, in: Capsule())
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Zoom control

    /// Stock-camera-style stops, with a fine slider that unfolds on demand.
    ///
    /// The old always-visible slider had two problems for the target user: it started
    /// at 1× (so the ultra-wide was unreachable), and it asked someone to dial in a
    /// continuous value when what they actually wanted was "the wide one" or "the
    /// zoomed one". Discrete stops are the common case; the slider is still there for
    /// the rarer in-between framing, one tap away.
    private var zoomControl: some View {
        VStack(spacing: 8) {
            if zoomExpanded { zoomFineSlider }
            zoomStopBar
        }
        .padding(.bottom, 10)
    }

    /// Index of the stop the current zoom belongs to — the highest stop at or below
    /// the live value, so 1.7× keeps the "1" chip lit (showing "1.7×") rather than
    /// leaving nothing selected.
    private var activeStopIndex: Int {
        var index = 0
        for (i, stop) in camera.zoomStops.enumerated() where stop <= camera.zoomFactor + 0.02 {
            index = i
        }
        return index
    }

    private var zoomStopBar: some View {
        HStack(spacing: 5) {
            ForEach(Array(camera.zoomStops.enumerated()), id: \.offset) { index, stop in
                let active = index == activeStopIndex
                Button {
                    if active {
                        withAnimation(.spring(duration: 0.28)) { zoomExpanded.toggle() }
                    } else {
                        camera.setZoom(stop, animated: true)
                        pinchStartZoom = stop
                        withAnimation(.spring(duration: 0.28)) { zoomExpanded = false }
                    }
                    Haptics.tap()
                } label: {
                    Text(active ? "\(liveZoomLabel)×" : zoomLabel(stop))
                        .font(.system(size: active ? 13 : 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(active ? .black : .white)
                        .padding(.horizontal, active ? 12 : 9)
                        .frame(minWidth: 36, minHeight: 34)
                        .background(active ? gold : Color.white.opacity(0.16), in: Capsule())
                }
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .animation(.spring(duration: 0.25), value: activeStopIndex)
    }

    private var zoomFineSlider: some View {
        HStack(spacing: 10) {
            Text("\(zoomLabel(camera.minZoom))×")
                .font(.caption2).foregroundColor(cyan.opacity(0.9))
            Slider(
                value: Binding(
                    get: { Double(camera.zoomFactor) },
                    set: { camera.setZoom(CGFloat($0)); pinchStartZoom = CGFloat($0) }
                ),
                in: Double(camera.minZoom)...Double(camera.maxZoom)
            )
            .tint(cyan)
            Text("\(zoomLabel(camera.maxZoom))×")
                .font(.caption2).foregroundColor(cyan.opacity(0.9))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// "0.5", "1", "2.5" — trailing ".0" dropped, since "2×" reads better than "2.0×".
    private func zoomLabel(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }

    private var liveZoomLabel: String { zoomLabel(camera.zoomFactor) }

    private func sanitizedIcon(_ name: String) -> String {
        UIImage(systemName: name) != nil ? name : "lightbulb.fill"
    }

    private func partnerHeartbeat() {
        // No coaching while a sheet covers the camera — the frame is stale anyway.
        guard partnerOn, !partnerLoading, !camera.isPaused, !anySheetPresented else { return }
        guard tokenManager.canUseAdvice else {
            partnerError = "Out of coaching tokens for today"
            return
        }

        if camera.motionLevel < 0.05 {
            if stillSince == nil { stillSince = Date() }
        } else {
            stillSince = nil
            return
        }
        guard let since = stillSince, Date().timeIntervalSince(since) > 0.9 else { return }
        guard Date().timeIntervalSince(lastTipAt) > 4.5 else { return }
        guard let snapshot = camera.currentSnapshot() else { return }

        partnerLoading = true
        partnerError = nil
        lastTipAt = Date()

        let rule = guidance.suggestedRule
        let subject = detector.subject
        let userSelected = detector.selectedPoint != nil
        let currentZoom = Double(camera.zoomFactor)
        let zoomRange = Double(camera.minZoom)...Double(camera.maxZoom)

        Task {
            do {
                let tip = try await AdviceService.partnerTip(
                    snapshot: snapshot,
                    rule: rule,
                    subject: subject,
                    userSelectedSubject: userSelected,
                    currentZoom: currentZoom,
                    zoomRange: zoomRange)
                await MainActor.run {
                    withAnimation { partnerTip = tip }
                    tokenManager.useAdviceToken()
                    partnerLoading = false
                }
            } catch {
                await MainActor.run {
                    partnerError = error.localizedDescription
                    partnerLoading = false
                }
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button { showGallery = true } label: {
                galleryThumb
            }

            Spacer()

            Button {
                camera.capturePhoto { image, info in
                    guard let image else { return }
                    let entry = PhotoStore.shared.save(image: image,
                                                       rule: guidance.suggestedRule,
                                                       info: info)
                    reviewEntry = entry
                    Haptics.tap()
                }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(duration: 0.3)) {
                    partnerOn.toggle()
                    if partnerOn {
                        // Pull back to the widest lens the phone has. Claude can only
                        // advise on what the frame contains, so asking it for help from
                        // inside a 3× crop hides exactly the information it needs —
                        // it can't suggest "there's a better angle to your left" or
                        // "step back and include the doorway" if neither is in shot.
                        // It hands a zoom back with its advice, so the user gets
                        // returned to a tighter framing deliberately rather than by
                        // guesswork.
                        zoomBeforeCoach = camera.zoomFactor
                        camera.setZoom(camera.minZoom, animated: true)
                        pinchStartZoom = camera.minZoom
                        zoomExpanded = false
                    } else {
                        partnerTip = nil
                        partnerError = nil
                        stillSince = nil
                        // Put the user back where they were framed before we intervened.
                        if let restore = zoomBeforeCoach {
                            camera.setZoom(restore, animated: true)
                            pinchStartZoom = restore
                        }
                        zoomBeforeCoach = nil
                    }
                }
                Haptics.tap()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: partnerOn ? "person.wave.2.fill" : "person.wave.2")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(partnerOn ? .black : .white)
                        .frame(width: 54, height: 54)
                        .background(partnerOn ? gold : Color.white.opacity(0.15), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
                    Text("Coach")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(partnerOn ? gold : .white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 24)
    }

    private var galleryThumb: some View {
        Group {
            if let last = PhotoStore.shared.entries.first, let thumb = PhotoStore.shared.thumbnail(for: last) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.5), lineWidth: 1))
            } else {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private var permissionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is off").font(.headline)
            Text("Enable it in Settings → Apollo Cam").font(.caption).foregroundColor(.secondary)
        }
        .foregroundColor(.white)
    }

    // MARK: - Rule picker

    /// A short, recognizable set rather than the full list of composition
    /// rules — kept deliberately small so this reads like a native control,
    /// not a photography-jargon menu.
    private static let curatedRules: [CompositionRule] = [.ruleOfThirds, .centeredCircle, .symmetry, .leadingLines]

    private var rulePicker: some View {
        NavigationView {
            List {
                Button {
                    selectedRule = nil; showRulePicker = false
                } label: {
                    Label("Auto (recommended)", systemImage: "wand.and.stars")
                        .foregroundColor(selectedRule == nil ? gold : .primary)
                }
                ForEach(Self.curatedRules) { rule in
                    Button {
                        selectedRule = rule; showRulePicker = false
                    } label: {
                        HStack {
                            Label(rule.rawValue, systemImage: rule.icon)
                            Spacer()
                            if selectedRule == rule { Image(systemName: "checkmark").foregroundColor(gold) }
                        }
                        .foregroundColor(selectedRule == rule ? gold : .primary)
                    }
                }
            }
            .navigationTitle("Composition guide")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Capture review

/// One label/value pair in the review screen's metadata strip.
struct MetaItem: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct CaptureReviewView: View {
    let entry: PhotoEntry

    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var showCritique = false
    @State private var showEditor = false
    @State private var displayImage: UIImage?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)
    private let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Photo — the screen is mostly the image.
                ZStack {
                    if let image = displayImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                metadataRow

                actionRow
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if displayImage == nil { displayImage = PhotoStore.shared.image(for: entry) } }
        .fullScreenCover(isPresented: $showCritique) {
            if let image = displayImage {
                CritiqueView(image: image, entryID: entry.id)
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            PhotoEditorView(entry: entry) { edited in
                PhotoStore.shared.replaceImage(edited, for: entry)
                displayImage = edited
                saved = false
            }
        }
    }

    // Two stacked rows, evenly divided — everything visible at once, no scrolling.
    private var metadataRow: some View {
        let items = metadataItems
        let half = Int((Double(items.count) / 2).rounded(.up))
        let top = Array(items.prefix(half))
        let bottom = Array(items.dropFirst(half))

        return VStack(spacing: 10) {
            metadataLine(top)
            if !bottom.isEmpty { metadataLine(bottom) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
    }

    /// One row of label/value pairs, spread across the full width.
    private func metadataLine(_ items: [MetaItem]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                    Text(item.value)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var metadataItems: [MetaItem] {
        var out: [MetaItem] = []

        if let w = entry.pixelWidth, let h = entry.pixelHeight {
            out.append(MetaItem(label: "Resolution", value: "\(w)×\(h)"))
            out.append(MetaItem(label: "Ratio", value: aspectLabel(w: w, h: h)))
        } else if let img = displayImage {
            let w = Int(img.size.width * img.scale), h = Int(img.size.height * img.scale)
            out.append(MetaItem(label: "Resolution", value: "\(w)×\(h)"))
            out.append(MetaItem(label: "Ratio", value: aspectLabel(w: w, h: h)))
        }

        if let rule = entry.rule {
            out.append(MetaItem(label: "Composition", value: rule.rawValue))
        }
        if let z = entry.zoom {
            out.append(MetaItem(label: "Zoom", value: String(format: "%.1f×", z)))
        }
        if let a = entry.aperture {
            out.append(MetaItem(label: "Aperture", value: String(format: "f/%.1f", a)))
        }
        if let s = entry.shutter, s > 0 {
            out.append(MetaItem(label: "Shutter", value: s >= 1 ? String(format: "%.1fs", s) : "1/\(Int((1/s).rounded()))s"))
        }
        if let iso = entry.iso {
            out.append(MetaItem(label: "ISO", value: "\(iso)"))
        }
        out.append(MetaItem(label: "Taken", value: entry.date.formatted(date: .omitted, time: .shortened)))
        return out
    }

    private func aspectLabel(w: Int, h: Int) -> String {
        guard w > 0, h > 0 else { return "—" }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(max(w, h), min(w, h))
        var rw = w / g, rh = h / g
        // Collapse awkward ratios like 4032:3024 → 4:3
        if rw > 20 || rh > 20 {
            let r = Double(w) / Double(h)
            let common: [(Double, String)] = [(4.0/3, "4:3"), (3.0/4, "3:4"), (16.0/9, "16:9"),
                                              (9.0/16, "9:16"), (1, "1:1"), (3.0/2, "3:2"), (2.0/3, "2:3")]
            if let best = common.min(by: { abs($0.0 - r) < abs($1.0 - r) }), abs(best.0 - r) < 0.04 {
                return best.1
            }
            rw = Int((r * 10).rounded()); rh = 10
        }
        return "\(rw):\(rh)"
    }

    private var actionRow: some View {
        HStack {
            // Bottom left: AI review
            Button {
                showCritique = true
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(gold)
                        .frame(width: 46, height: 46)
                        .background(gold.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(gold.opacity(0.45), lineWidth: 1))
                    Text("AI review")
                        .font(.system(size: 10))
                        .foregroundColor(gold)
                }
            }

            Spacer()

            // Centre: edit + dismiss
            HStack(spacing: 22) {
                Button {
                    showEditor = true
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                        Text("Edit")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }

                Button {
                    dismiss()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                        Text("Shoot")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }

            Spacer()

            // Bottom right: save
            Button {
                if let image = displayImage {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    saved = true
                    Haptics.success()
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(width: 46, height: 46)
                        .background(saved ? Color.green : cyan, in: RoundedRectangle(cornerRadius: 11))
                    Text(saved ? "Saved" : "Save")
                        .font(.system(size: 10))
                        .foregroundColor(saved ? .green : cyan)
                }
            }
            .disabled(saved || displayImage == nil)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }
}
