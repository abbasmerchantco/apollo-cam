import SwiftUI
import Combine

struct CameraScreen: View {
    @StateObject private var camera = CameraController()
    @StateObject private var detector = SubjectDetector()
    @ObservedObject private var tokenManager = TokenManager.shared

    // Composition
    @State private var selectedRule: CompositionRule? = nil   // nil = auto
    @State private var guidance = Guidance(message: "Point at your subject", tip: nil, aligned: false, suggestedRule: .ruleOfThirds, ruleFromModel: false, scene: .general)
    @State private var wasAligned = false
    @State private var showRulePicker = false

    // Capture review
    @State private var reviewEntry: PhotoEntry?

    // Sheets
    @State private var showGallery = false
    @State private var showSettings = false

    // AI Partner
    @State private var partnerOn = false
    @State private var partnerTip: CoachTip?
    @State private var partnerLoading = false
    @State private var partnerError: String?
    @State private var stillSince: Date?
    @State private var lastTipAt = Date.distantPast
    private let heartbeat = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)

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

                    CompositionOverlay(rule: guidance.suggestedRule, aligned: guidance.aligned)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    subjectBox(in: geo.size)

                    VStack(spacing: 0) {
                        topBar
                        Spacer()
                        if partnerOn { partnerCard }
                        guidanceStrip
                        bottomBar
                    }
                }
            }
            .onAppear {
                camera.configure()
                camera.onFrame = { buffer in detector.analyze(buffer) }
            }
            .onDisappear { camera.stop() }
            .onReceive(detector.$subject) { _ in
                let g = GuidanceEngine.evaluate(
                    subject: detector.subject,
                    personCount: detector.personCount,
                    modelRule: detector.modelRule,
                    rule: selectedRule,
                    brightness: detector.brightness,
                    viewSize: geo.size)
                if g.aligned && !wasAligned { Haptics.alignedPing() }
                wasAligned = g.aligned
                withAnimation(.easeInOut(duration: 0.2)) { guidance = g }
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
                RoundedRectangle(cornerRadius: 10)
                    .stroke(guidance.aligned ? .green : gold,
                            style: StrokeStyle(lineWidth: 2, dash: detector.selectedPoint == nil ? [6, 5] : []))

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
                            .background(Color(red: 0.98, green: 0.75, blue: 0.24), in: Capsule())
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundColor(.white)

            Spacer()

            zoomControl

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

    private var zoomControl: some View {
        HStack(spacing: 2) {
            ForEach([1.0, 2.0, 5.0], id: \.self) { z in
                Button { camera.setZoom(z) } label: {
                    Text(z == 1.0 ? "1×" : String(format: "%.0f×", z))
                        .font(.caption.weight(abs(camera.zoomFactor - z) < 0.3 ? .bold : .regular))
                        .foregroundColor(abs(camera.zoomFactor - z) < 0.3 ? gold : .white)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                }
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var guidanceStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: guidance.aligned ? "checkmark.circle.fill" : "scope")
                    .foregroundColor(guidance.aligned ? .green : gold)
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
                        .background(gold, in: Capsule())
                }
            }
            if let tip = guidance.tip {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.caption2)
                        .foregroundColor(gold.opacity(0.9))
                    Text(tip)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
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
        guard partnerOn, !partnerLoading else { return }
        guard tokenManager.canUseAdvice else {
            partnerError = "Out of coaching tokens for today"
            return
        }

        if camera.motionLevel < 0.045 {
            if stillSince == nil { stillSince = Date() }
        } else {
            stillSince = nil
            return
        }
        guard let since = stillSince, Date().timeIntervalSince(since) > 1.2 else { return }
        guard Date().timeIntervalSince(lastTipAt) > 6.0 else { return }
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
                camera.capturePhoto { image in
                    guard let image else { return }
                    let entry = PhotoStore.shared.save(image: image, rule: guidance.suggestedRule)
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

// MARK: - Capture review (Save to Photos / Evaluate)

struct CaptureReviewView: View {
    let entry: PhotoEntry

    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var showCritique = false

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)
    private var image: UIImage? { PhotoStore.shared.image(for: entry) }

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    Button {
                        if let image {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                            saved = true
                            Haptics.success()
                        }
                    } label: {
                        Label(saved ? "Saved" : "Save to Photos",
                              systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(saved ? .green : gold)
                    .foregroundColor(.black)
                    .disabled(saved)

                    Button {
                        showCritique = true
                    } label: {
                        Label("Evaluate", systemImage: "sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(gold)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Your shot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showCritique) {
            if let image {
                CritiqueView(image: image, entryID: entry.id)
            }
        }
    }
}
