import SwiftUI

struct CameraScreen: View {
    @StateObject private var camera = CameraController()
    @StateObject private var detector = SubjectDetector()
    @StateObject private var tokenManager = TokenManager.shared

    @State private var selectedRule: CompositionRule? = nil   // nil = auto
    @State private var guidance = Guidance(message: "Looking for a subject…", aligned: false, suggestedRule: .ruleOfThirds)
    @State private var wasAligned = false
    @State private var showRulePicker = false
    @State private var captured: UIImage?
    @State private var showCritique = false
    @State private var showAdviceModal = false
    @State private var currentFrameBuffer: CVPixelBuffer?
    @State private var adviceCards: [AdviceCard] = []
    @State private var adviceLoading = false
    @State private var adviceError: String?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                if camera.permissionDenied {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text("Camera access is off").font(.headline)
                        Text("Enable it in Settings → Apollo Cam").font(.caption).foregroundColor(.secondary)
                    }
                    .foregroundColor(.white)
                } else {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()

                    CompositionOverlay(rule: guidance.suggestedRule, aligned: guidance.aligned)
                        .ignoresSafeArea()

                    // Subject bounding box
                    if let subject = detector.subject {
                        let box = CGRect(
                            x: subject.box.origin.x * geo.size.width,
                            y: subject.box.origin.y * geo.size.height,
                            width: subject.box.width * geo.size.width,
                            height: subject.box.height * geo.size.height)
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(guidance.aligned ? .green : gold, lineWidth: 2)
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                            .animation(.easeOut(duration: 0.25), value: subject.box)
                            .allowsHitTesting(false)
                    }

                    VStack {
                        topBar
                        Spacer()
                        guidanceBanner
                        bottomBar
                    }
                    .padding(.bottom, 8)
                }
            }
            .onAppear {
                camera.configure()
                camera.onFrame = { buffer in 
                    detector.analyze(buffer)
                    currentFrameBuffer = buffer
                }
            }
            .onDisappear { camera.stop() }
            .onReceive(detector.$subject) { _ in
                let g = GuidanceEngine.evaluate(
                    subject: detector.subject,
                    rule: selectedRule,
                    brightness: detector.brightness,
                    viewSize: geo.size)
                if g.aligned && !wasAligned { Haptics.alignedPing() }
                wasAligned = g.aligned
                withAnimation(.easeInOut(duration: 0.2)) { guidance = g }
            }
        }
        .sheet(isPresented: $showRulePicker) { rulePicker }
        .sheet(isPresented: $showAdviceModal) { adviceSheet }
        .fullScreenCover(isPresented: $showCritique) {
            if let img = captured {
                CritiqueView(image: img)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { showRulePicker = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: guidance.suggestedRule.icon)
                    Text(selectedRule == nil ? "Auto · \(guidance.suggestedRule.rawValue)" : guidance.suggestedRule.rawValue)
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundColor(.white)
            Spacer()
            zoomControl
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var zoomControl: some View {
        HStack(spacing: 4) {
            ForEach([1.0, 2.0, 5.0], id: \.self) { z in
                Button {
                    camera.setZoom(z)
                } label: {
                    Text(z == 1.0 ? "1×" : String(format: "%.0f×", z))
                        .font(.footnote.weight(abs(camera.zoomFactor - z) < 0.3 ? .bold : .regular))
                        .foregroundColor(abs(camera.zoomFactor - z) < 0.3 ? gold : .white)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var guidanceBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: guidance.aligned ? "checkmark.circle.fill" : "scope")
                .foregroundColor(guidance.aligned ? .green : gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(guidance.message)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.white)
                Text(guidance.suggestedRule.hint)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                adviceLoading = true
                adviceError = nil
                Task {
                    if tokenManager.canUseAdvice {
                        await requestAdvice()
                    } else {
                        adviceError = "No advice tokens left today"
                        adviceLoading = false
                    }
                }
            } label: {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(width: 52, height: 52)
                    .background(gold.opacity(adviceLoading ? 0.6 : 1), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
            }
            .disabled(adviceLoading || !tokenManager.canUseAdvice)
            
            Spacer()
            
            Button {
                camera.capturePhoto { image in
                    guard let image else { return }
                    PhotoStore.shared.save(image: image, rule: guidance.suggestedRule)
                    captured = image
                    showCritique = true
                }
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                    Circle().fill(.white).frame(width: 60, height: 60)
                }
            }
            
            Spacer()
            NavigationHintGallery()
        }
        .padding(.horizontal, 16)
    }
    
    private func requestAdvice() async {
        guard let buffer = currentFrameBuffer else {
            adviceError = "No camera frame available"
            adviceLoading = false
            return
        }
        
        do {
            let cards = try await AdviceService.getAdvice(
                frameBuffer: buffer,
                rule: guidance.suggestedRule,
                subject: detector.subject
            )
            adviceCards = cards
            tokenManager.useAdviceToken()
            showAdviceModal = true
        } catch {
            adviceError = error.localizedDescription
        }
        adviceLoading = false
    }
}

/// Small last-photo thumbnail linking to gallery tab (visual hint only).
struct NavigationHintGallery: View {
    @ObservedObject private var store = PhotoStore.shared
    var body: some View {
        Group {
            if let last = store.entries.first, let thumb = store.thumbnail(for: last) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.4), lineWidth: 1))
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .frame(width: 64, height: 64)
    }
}

extension CameraScreen {
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
    
    private var adviceSheet: some View {
        NavigationView {
            VStack(spacing: 16) {
                if adviceLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Your coach is analyzing the scene…")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                } else if let error = adviceError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange).font(.title2)
                        Text(error)
                            .font(.footnote).multilineTextAlignment(.center)
                        Button("Dismiss") { showAdviceModal = false }
                            .buttonStyle(.borderedProminent).tint(gold)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(adviceCards) { card in
                                adviceCardView(card)
                            }
                        }
                        .padding()
                    }
                }
                Spacer()
            }
            .navigationTitle("Coach's advice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showAdviceModal = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private func adviceCardView(_ card: AdviceCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: card.icon)
                    .foregroundColor(gold)
                Text(card.title)
                    .font(.headline)
                Spacer()
            }
            Text(card.advice)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
