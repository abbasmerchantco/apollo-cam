import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Adjustment model

/// Non-destructive edit state. Every value is 0 at neutral, so `EditAdjustments()`
/// is always "the original image".
struct EditAdjustments: Codable, Equatable {
    var exposure: Double = 0      // -2 ... 2   (EV)
    var brightness: Double = 0    // -1 ... 1
    var contrast: Double = 0      // -1 ... 1
    var saturation: Double = 0    // -1 ... 1
    var warmth: Double = 0        // -1 ... 1   (cool → warm)
    var tint: Double = 0          // -1 ... 1   (green → magenta)
    var highlights: Double = 0    // -1 ... 1   (recover → lift)
    var shadows: Double = 0       // -1 ... 1   (crush → lift)
    var sharpness: Double = 0     //  0 ... 1
    var vignette: Double = 0      //  0 ... 1

    // Orientation
    var rotationQuarters: Int = 0 // number of 90° clockwise turns
    var flipH: Bool = false

    var isNeutral: Bool { self == EditAdjustments() }
}

/// One editable parameter, described once so the UI can be generated from it.
struct EditTool: Identifiable {
    let id: String
    let name: String
    let icon: String
    let range: ClosedRange<Double>
    let keyPath: WritableKeyPath<EditAdjustments, Double>

    static let all: [EditTool] = [
        EditTool(id: "exposure",   name: "Exposure",   icon: "sun.max",                  range: -2...2, keyPath: \.exposure),
        EditTool(id: "brightness", name: "Brightness", icon: "light.max",                range: -1...1, keyPath: \.brightness),
        EditTool(id: "contrast",   name: "Contrast",   icon: "circle.lefthalf.filled",   range: -1...1, keyPath: \.contrast),
        EditTool(id: "saturation", name: "Saturation", icon: "drop.fill",                range: -1...1, keyPath: \.saturation),
        EditTool(id: "warmth",     name: "Warmth",     icon: "thermometer.medium",       range: -1...1, keyPath: \.warmth),
        EditTool(id: "tint",       name: "Tint",       icon: "eyedropper.halffull",      range: -1...1, keyPath: \.tint),
        EditTool(id: "highlights", name: "Highlights", icon: "circle.tophalf.filled",    range: -1...1, keyPath: \.highlights),
        EditTool(id: "shadows",    name: "Shadows",    icon: "circle.bottomhalf.filled", range: -1...1, keyPath: \.shadows),
        EditTool(id: "sharpness",  name: "Sharpen",    icon: "triangle",                 range:  0...1, keyPath: \.sharpness),
        EditTool(id: "vignette",   name: "Vignette",   icon: "circle.dashed",            range:  0...1, keyPath: \.vignette)
    ]
}

// MARK: - Rendering pipeline

enum ImagePipeline {
    /// Shared context — creating a CIContext per render is very expensive.
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Applies adjustments and returns a new UIImage. Pure: never mutates the input.
    static func apply(_ adj: EditAdjustments, to image: UIImage) -> UIImage {
        guard var ci = CIImage(image: image) else { return image }

        // 1. Orientation first, so later filters work on the final framing.
        if adj.flipH {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                   .transformed(by: CGAffineTransform(translationX: ci.extent.width, y: 0))
        }
        let turns = ((adj.rotationQuarters % 4) + 4) % 4
        if turns != 0 {
            let angle = -CGFloat(turns) * .pi / 2
            ci = ci.transformed(by: CGAffineTransform(rotationAngle: angle))
            // Re-origin so extent starts at zero after rotating.
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }

        // 2. Exposure (EV).
        if adj.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = ci
            f.ev = Float(adj.exposure)
            ci = f.outputImage ?? ci
        }

        // 3. Highlights / shadows via a tone curve — behaves well in both directions,
        //    unlike CIHighlightShadowAdjust which only recovers.
        if adj.highlights != 0 || adj.shadows != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = ci
            let shadowLift = Float(adj.shadows) * 0.15
            let highlightLift = Float(adj.highlights) * 0.15
            f.point0 = CGPoint(x: 0, y: 0)
            f.point1 = CGPoint(x: 0.25, y: CGFloat(min(max(0.25 + shadowLift, 0), 1)))
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: CGFloat(min(max(0.75 + highlightLift, 0), 1)))
            f.point4 = CGPoint(x: 1, y: 1)
            ci = f.outputImage ?? ci
        }

        // 4. Brightness / contrast / saturation.
        if adj.brightness != 0 || adj.contrast != 0 || adj.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = ci
            f.brightness = Float(adj.brightness * 0.3)
            f.contrast = Float(1.0 + adj.contrast * 0.5)
            f.saturation = Float(1.0 + adj.saturation)
            ci = f.outputImage ?? ci
        }

        // 5. Warmth / tint.
        if adj.warmth != 0 || adj.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = ci
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(6500 - adj.warmth * 1500),
                                       y: CGFloat(adj.tint * 60))
            ci = f.outputImage ?? ci
        }

        // 6. Sharpen.
        if adj.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = ci
            f.sharpness = Float(adj.sharpness * 1.5)
            ci = f.outputImage ?? ci
        }

        // 7. Vignette.
        if adj.vignette > 0 {
            let f = CIFilter.vignette()
            f.inputImage = ci
            f.intensity = Float(adj.vignette * 2.0)
            f.radius = 1.5
            ci = f.outputImage ?? ci
        }

        guard let cg = context.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }

    /// Small proxy used for live slider feedback so we aren't filtering 12MP per frame.
    static func preview(from image: UIImage, maxSide: CGFloat = 1400) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Editor screen

struct PhotoEditorView: View {
    let entry: PhotoEntry
    /// Called with the edited image when the user saves.
    var onSave: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tokenManager = TokenManager.shared

    @State private var adj = EditAdjustments()
    @State private var selectedTool: EditTool = EditTool.all[0]
    @State private var original: UIImage?
    @State private var proxy: UIImage?
    @State private var rendered: UIImage?
    @State private var showingOriginal = false

    // AI adjust
    @State private var aiLoading = false
    @State private var aiNote: String?
    @State private var aiError: String?

    private let cyan = Color(red: 0.0, green: 0.9, blue: 1.0)
    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                imageArea
                if let note = aiNote { aiNoteBar(note) }
                if let err = aiError { errorBar(err) }
                sliderRow
                toolStrip
                actionRow
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .foregroundColor(cyan)
                        .fontWeight(.semibold)
                        .disabled(original == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    // MARK: Image

    private var imageArea: some View {
        ZStack {
            Color.black
            if let shown = showingOriginal ? proxy : (rendered ?? proxy) {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }

            if showingOriginal {
                VStack {
                    Text("ORIGINAL")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.white, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Press and hold anywhere on the photo to compare against the original.
        .onLongPressGesture(minimumDuration: 0.08, maximumDistance: 50) {
        } onPressingChanged: { pressing in
            showingOriginal = pressing
        }
    }

    // MARK: Slider

    private var sliderRow: some View {
        VStack(spacing: 4) {
            HStack {
                Text(selectedTool.name)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.85))
                Spacer()
                Text(valueLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(cyan)
                Button {
                    adj[keyPath: selectedTool.keyPath] = 0
                    render()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            Slider(
                value: Binding(
                    get: { adj[keyPath: selectedTool.keyPath] },
                    set: { adj[keyPath: selectedTool.keyPath] = $0; render() }
                ),
                in: selectedTool.range
            )
            .tint(cyan)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var valueLabel: String {
        let v = adj[keyPath: selectedTool.keyPath]
        return String(format: v > 0 ? "+%.2f" : "%.2f", v)
    }

    // MARK: Tools

    private var toolStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(EditTool.all) { tool in
                    let active = tool.id == selectedTool.id
                    let touched = adj[keyPath: tool.keyPath] != 0
                    Button {
                        selectedTool = tool
                    } label: {
                        VStack(spacing: 5) {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: tool.icon)
                                    .font(.system(size: 17))
                                    .frame(width: 42, height: 42)
                                    .background(active ? cyan.opacity(0.22) : Color.white.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(active ? cyan : .clear, lineWidth: 1)
                                    )
                                if touched {
                                    Circle().fill(cyan).frame(width: 6, height: 6).offset(x: 3, y: -3)
                                }
                            }
                            Text(tool.name)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(active ? cyan : .white.opacity(0.75))
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.top, 12)
    }

    // MARK: Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                adj.rotationQuarters += 1
                render()
            } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 44, height: 40)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            Button {
                adj.flipH.toggle()
                render()
            } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .frame(width: 44, height: 40)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            Button {
                aiAdjust()
            } label: {
                HStack(spacing: 6) {
                    if aiLoading {
                        ProgressView().tint(.black).scaleEffect(0.7)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(aiLoading ? "Analysing…" : "AI adjust")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .foregroundColor(.black)
                .background(gold, in: RoundedRectangle(cornerRadius: 9))
            }
            .disabled(aiLoading || original == nil)

            Button {
                adj = EditAdjustments()
                aiNote = nil
                render()
            } label: {
                Text("Reset")
                    .font(.subheadline)
                    .frame(width: 62, height: 40)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            .disabled(adj.isNeutral)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private func aiNoteBar(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wand.and.stars").font(.caption).foregroundColor(gold)
            Text(note)
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private func errorBar(_ msg: String) -> some View {
        Text(msg)
            .font(.caption)
            .foregroundColor(.orange)
            .padding(.horizontal, 18)
            .padding(.top, 10)
    }

    // MARK: Work

    private func load() {
        guard original == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let full = PhotoStore.shared.image(for: entry)
            let small = full.map { ImagePipeline.preview(from: $0) }
            DispatchQueue.main.async {
                original = full
                proxy = small
                rendered = small
            }
        }
    }

    /// Re-renders the small proxy only — full resolution is rendered once on save.
    private func render() {
        guard let proxy else { return }
        let snapshot = adj
        DispatchQueue.global(qos: .userInitiated).async {
            let out = ImagePipeline.apply(snapshot, to: proxy)
            DispatchQueue.main.async {
                // Discard if the user moved the slider again while we rendered.
                if snapshot == adj { rendered = out }
            }
        }
    }

    private func save() {
        guard let original else { return }
        let snapshot = adj
        DispatchQueue.global(qos: .userInitiated).async {
            let full = snapshot.isNeutral ? original : ImagePipeline.apply(snapshot, to: original)
            DispatchQueue.main.async {
                onSave(full)
                Haptics.success()
                dismiss()
            }
        }
    }

    private func aiAdjust() {
        guard let proxy else { return }
        guard tokenManager.canUseEval else {
            aiError = "Out of AI tokens for today"
            return
        }
        aiLoading = true
        aiError = nil
        Task {
            do {
                let result = try await AdjustService.suggestAdjustments(for: proxy)
                await MainActor.run {
                    withAnimation {
                        adj = result.adjustments
                        aiNote = result.note
                    }
                    tokenManager.useEvalToken()
                    aiLoading = false
                    render()
                }
            } catch {
                await MainActor.run {
                    aiError = error.localizedDescription
                    aiLoading = false
                }
            }
        }
    }
}
