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

    // Sheets
    @State private var showGallery = false
    @State private var showSettings = false

    // Zoom
    @State private var pinchStartZoom: CGFloat = 1.0

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
                                    detector.select(at: pt)
                                    Haptics.tap()
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

                    CompositionOverlay(rule: guidance.suggestedRule,
                                       aligned: guidance.aligned,
                                       focusPoint: guidance.focusPoint)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    subjectBox(in: geo.size)

                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        if partnerOn { partnerCard }
                        tipStack
                        zoomSlider
                        sceneSelector
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

    // MARK: - Subject box

    @ViewBuilder
    private func subjectBox(in size: CGSize) -> some View {
        if let subject = detector.subject {
            let box = CGRect(
                x: subject.box.origin.x * size.width,
                y: subject.box.origin.y * size.height,
                width: subject.box.width * size.width,
                height: subject.box.height * size.height)

            ZStack(alignment: .topTrailing) {
                CornerBrackets(aligned: guidance.aligned)

                if detector.selectedPoint != nil {
                    Button {
                        detector.clearSelection()
                        Haptics.tap()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .background(Circle().fill(.black.opacity(0.5)))
                    }
                    .offset(x: 10, y: -10)
                }

                if let label = subject.label {
                    Text(label.capitalized)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(guidance.aligned ? Color.green : cyan, in: Capsule())
                        .offset(y: -22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: box.width, height: box.height)
            .position(x: box.midX, y: box.midY)
            .animation(.easeOut(duration: 0.25), value: subject.box)
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Button { showRulePicker = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: guidance.suggestedRule.icon)
                    Text(selectedRule == nil ? (guidance.ruleFromModel ? guidance.suggestedRule.rawValue : "Auto") : guidance.suggestedRule.rawValue)
                        .font(.footnote.weight(.medium))
                    if guidance.ruleFromModel && selectedRule == nil {
                        Text("AI")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(gold, in: Capsule())
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundColor(.white)

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

    // MARK: - Stacked tip cards

    /// Fixed geometry for the tip block. The card count changes several times a
    /// second as scene/lighting flip, and when the block grew or shrank it pushed
    /// the zoom slider, scene pills and shutter row up and down with it — taps
    /// landed on the wrong control or were dropped mid-animation. Reserving a
    /// constant height keeps everything below perfectly still.
    private static let tipCardHeight: CGFloat = 46
    private static let tipCardSpacing: CGFloat = 7
    private static let maxTipCards = 3
    private static var tipAreaHeight: CGFloat {
        CGFloat(maxTipCards) * tipCardHeight + CGFloat(maxTipCards - 1) * tipCardSpacing
    }

    private var tipStack: some View {
        VStack(spacing: 7) {
            // Alignment status always leads.
            HStack(spacing: 8) {
                Image(systemName: guidance.aligned ? "checkmark.circle.fill" : "scope")
                    .foregroundColor(guidance.aligned ? .green : cyan)
                Text(guidance.message)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if guidance.scene != .general {
                    Text(guidance.scene.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(guidance.sceneFromUser ? gold : cyan, in: Capsule())
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            // Fixed-height container, cards pinned to the bottom. Fewer than three
            // tips just leaves empty space at the top — nothing below ever moves.
            VStack(spacing: Self.tipCardSpacing) {
                Spacer(minLength: 0)
                ForEach(Array(guidance.tips.prefix(Self.maxTipCards))) { tip in
                    HStack(alignment: .center, spacing: 9) {
                        Image(systemName: tip.icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(cyan)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tip.title)
                                .font(.caption2.weight(.bold))
                                .foregroundColor(cyan)
                                .lineLimit(1)
                            Text(tip.body)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: Self.tipCardHeight)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(height: Self.tipAreaHeight, alignment: .bottom)
            .animation(.easeInOut(duration: 0.2), value: guidance.tips)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Zoom slider

    private var zoomSlider: some View {
        HStack(spacing: 10) {
            Text("1×")
                .font(.caption2)
                .foregroundColor(cyan.opacity(0.9))
            Slider(
                value: Binding(
                    get: { Double(camera.zoomFactor) },
                    set: { camera.setZoom(CGFloat($0)); pinchStartZoom = CGFloat($0) }
                ),
                in: 1...Double(camera.maxZoom)
            )
            .tint(cyan)
            Text(String(format: "%.0f×", camera.maxZoom))
                .font(.caption2)
                .foregroundColor(cyan.opacity(0.9))
            Text(String(format: "%.1f×", camera.zoomFactor))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundColor(cyan)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Scene selector

    private var sceneSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                scenePill(title: "AUTO", active: sceneOverride == nil) {
                    sceneOverride = nil
                }
                ForEach(SceneKind.selectable) { kind in
                    scenePill(title: kind.pill, active: sceneOverride == kind) {
                        sceneOverride = (sceneOverride == kind) ? nil : kind
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 10)
    }

    private func scenePill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(active ? .black : .white.opacity(0.7))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? cyan : Color.white.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(active ? .clear : .white.opacity(0.2), lineWidth: 1))
        }
    }

    // MARK: - AI Partner

    private var partnerCard: some View {
        Group {
            if partnerLoading && partnerTip == nil {
                HStack(spacing: 10) {
                    ProgressView().tint(gold)
                    Text("Coach is looking…")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.bottom, 6)
            } else if let tip = partnerTip {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: sanitizedIcon(tip.icon))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(gold)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.title.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundColor(gold)
                        Text(tip.advice)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        if let scene = tip.scene, !scene.isEmpty {
                            Text("Sees: \(scene)")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if partnerLoading { ProgressView().tint(gold.opacity(0.6)).scaleEffect(0.8) }
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(tip.id)
            } else if let err = partnerError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            } else {
                Text("Hold the framing steady and your coach will chime in")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
        }
        .animation(.spring(duration: 0.35), value: partnerTip)
    }

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

        Task {
            do {
                let tip = try await AdviceService.partnerTip(
                    snapshot: snapshot,
                    rule: rule,
                    subject: subject,
                    userSelectedSubject: userSelected)
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
                    if !partnerOn {
                        partnerTip = nil
                        partnerError = nil
                        stillSince = nil
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

    private var rulePicker: some View {
        NavigationView {
            List {
                Button {
                    selectedRule = nil; showRulePicker = false
                } label: {
                    Label("Auto (recommended)", systemImage: "wand.and.stars")
                        .foregroundColor(selectedRule == nil ? gold : .primary)
                }
                ForEach(CompositionRule.allCases) { rule in
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

// MARK: - Viewfinder-style corner brackets

struct CornerBrackets: View {
    let aligned: Bool
    private let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let len = min(w, h) * 0.26
            Path { p in
                // top-left
                p.move(to: CGPoint(x: 0, y: len)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: len, y: 0))
                // top-right
                p.move(to: CGPoint(x: w - len, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: len))
                // bottom-right
                p.move(to: CGPoint(x: w, y: h - len)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - len, y: h))
                // bottom-left
                p.move(to: CGPoint(x: len, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - len))
            }
            .stroke(aligned ? Color.green : cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
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
