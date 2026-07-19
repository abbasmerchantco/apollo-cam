import SwiftUI

struct CameraScreen: View {
    @StateObject private var camera = CameraController()
    @StateObject private var detector = SubjectDetector()

    @State private var selectedRule: CompositionRule? = nil   // nil = auto
    @State private var guidance = Guidance(message: "Looking for a subject…", aligned: false, suggestedRule: .ruleOfThirds)
    @State private var wasAligned = false
    @State private var showRulePicker = false
    @State private var captured: UIImage?
    @State private var showCritique = false

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
                camera.onFrame = { buffer in detector.analyze(buffer) }
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
        HStack {
            Color.clear.frame(width: 64, height: 64)
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
        .padding(.horizontal, 24)
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
}
