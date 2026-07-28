import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
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

    // Crop — normalized (0...1), top-left origin, relative to the image
    // *after* orientation has been applied. (0,0,1,1) means "no crop".
    var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

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

private extension UIImage.Orientation {
    /// UIKit and Core Image describe orientation with two different enums whose
    /// cases correspond one-to-one by name but not by raw value, so map explicitly.
    var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up:            return .up
        case .upMirrored:    return .upMirrored
        case .down:          return .down
        case .downMirrored:  return .downMirrored
        case .left:          return .left
        case .leftMirrored:  return .leftMirrored
        case .right:         return .right
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}

enum ImagePipeline {
    /// Shared context — creating a CIContext per render is very expensive.
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Applies adjustments and returns a new UIImage. Pure: never mutates the input.
    static func apply(_ adj: EditAdjustments, to image: UIImage) -> UIImage {
        // 0. Bake `imageOrientation` into the pixels before anything else.
        //
        //    Core Image operates on the raw CGImage buffer and ignores UIKit's
        //    `imageOrientation`. A camera capture is almost always `.right` (the
        //    sensor is landscape), so without this step every transform below runs
        //    in sensor space while the result is written back out as `.up` —
        //    landing 90° away from what the user framed. The preview path escaped
        //    this because `preview(from:)` re-draws through `UIImage.draw`, which
        //    *does* honour orientation; that mismatch is why previews looked right
        //    and only saves came out rotated.
        let base: CIImage
        if let cg = image.cgImage {
            base = CIImage(cgImage: cg)
        } else if let existing = image.ciImage {
            base = existing
        } else {
            return image
        }
        var ci = base.oriented(image.imageOrientation.cgImageOrientation)
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                  y: -ci.extent.origin.y))

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

        // 1.5. Crop — normalized rect relative to the now-oriented image. Core
        // Image's coordinate origin is bottom-left, so the y-axis is flipped
        // relative to the UI's top-left-origin crop rect.
        if adj.cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) {
            let ext = ci.extent
            let r = adj.cropRect
            let pixelCrop = CGRect(
                x: ext.origin.x + r.minX * ext.width,
                y: ext.origin.y + (1 - r.maxY) * ext.height,
                width: r.width * ext.width,
                height: r.height * ext.height
            ).intersection(ext)
            if !pixelCrop.isEmpty {
                ci = ci.cropped(to: pixelCrop)
                ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                          y: -ci.extent.origin.y))
            }
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

    /// Maps a normalized (0...1, top-left origin) rect from the *un-oriented* image
    /// frame into the frame produced by `flipH` + `rotationQuarters` — which is the
    /// frame `EditAdjustments.cropRect` is defined against.
    ///
    /// Used for AI crop suggestions: the analysis is done on the un-rotated proxy,
    /// so the returned rect has to be carried through the same orientation steps
    /// `apply()` performs. Normalized coordinates rotate cleanly even though the
    /// aspect ratio flips, because each frame is normalized against its own bounds.
    static func orientedCropRect(_ rect: CGRect, quarters: Int, flipH: Bool) -> CGRect {
        var a = CGPoint(x: rect.minX, y: rect.minY)
        var b = CGPoint(x: rect.maxX, y: rect.maxY)

        // Mirror first, matching the order in `apply()`.
        if flipH {
            a.x = 1 - a.x
            b.x = 1 - b.x
        }

        // Each quarter turn clockwise sends (u, v) to (1 - v, u).
        let turns = ((quarters % 4) + 4) % 4
        for _ in 0..<turns {
            a = CGPoint(x: 1 - a.y, y: a.x)
            b = CGPoint(x: 1 - b.y, y: b.x)
        }

        return CGRect(x: min(a.x, b.x),
                      y: min(a.y, b.y),
                      width: abs(b.x - a.x),
                      height: abs(b.y - a.y))
    }
}

// MARK: - Crop overlay

/// Draggable crop rectangle shown over the un-cropped, orientation-corrected
/// preview. `rect` is normalized (0...1) with a top-left origin, matching
/// `EditAdjustments.cropRect`.
private struct CropOverlay: View {
    @Binding var rect: CGRect
    let imageSize: CGSize

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    private let minSize: CGFloat = 0.08
    private let handleTouchSize: CGFloat = 30

    @State private var moveStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let content = Self.contentRect(imageSize: imageSize, container: geo.size)
            let frame = pixelRect(rect, in: content)

            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                grid(in: frame)

                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(content: content))

                ForEach(Corner.allCases, id: \.self) { corner in
                    handle(corner, frame: frame, content: content)
                }
            }
        }
    }

    /// Thirds grid plus a brighter centre cross, drawn inside the crop rect.
    ///
    /// Two different jobs, which is why the centre is drawn separately rather than
    /// just being another grid line. The thirds lines are for placing a subject; the
    /// centre cross is for *symmetry* — lining a doorway, reflection or horizon up so
    /// it sits truly central. That is impossible to judge by eye against thirds
    /// alone, because neither third is the middle. Both live inside the crop rect,
    /// not the whole image, since what matters is the composition being cropped TO.
    private func grid(in frame: CGRect) -> some View {
        ZStack {
            Path { p in
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: frame.minY))
                    p.addLine(to: CGPoint(x: x, y: frame.maxY))
                    let y = frame.minY + frame.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: frame.minX, y: y))
                    p.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)

            Path { p in
                p.move(to: CGPoint(x: frame.midX, y: frame.minY))
                p.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
                p.move(to: CGPoint(x: frame.minX, y: frame.midY))
                p.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            }
            .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
        }
        .allowsHitTesting(false)
    }

    private func handle(_ corner: Corner, frame: CGRect, content: CGRect) -> some View {
        let point: CGPoint = {
            switch corner {
            case .topLeft: return CGPoint(x: frame.minX, y: frame.minY)
            case .topRight: return CGPoint(x: frame.maxX, y: frame.minY)
            case .bottomLeft: return CGPoint(x: frame.minX, y: frame.maxY)
            case .bottomRight: return CGPoint(x: frame.maxX, y: frame.maxY)
            }
        }()
        return Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
            .frame(width: 14, height: 14)
            .frame(width: handleTouchSize, height: handleTouchSize) // larger hit target than visible dot
            .contentShape(Circle())
            .position(point)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        updateCorner(corner, to: value.location, content: content)
                    }
            )
    }

    private func moveGesture(content: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = moveStart ?? rect
                if moveStart == nil { moveStart = rect }
                guard content.width > 0, content.height > 0 else { return }
                let dx = value.translation.width / content.width
                let dy = value.translation.height / content.height
                var r = start
                r.origin.x = min(max(start.origin.x + dx, 0), 1 - start.width)
                r.origin.y = min(max(start.origin.y + dy, 0), 1 - start.height)
                rect = r
            }
            .onEnded { _ in moveStart = nil }
    }

    private func updateCorner(_ corner: Corner, to location: CGPoint, content: CGRect) {
        guard content.width > 0, content.height > 0 else { return }
        let nx = min(max((location.x - content.minX) / content.width, 0), 1)
        let ny = min(max((location.y - content.minY) / content.height, 0), 1)

        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch corner {
        case .topLeft:
            minX = min(nx, maxX - minSize)
            minY = min(ny, maxY - minSize)
        case .topRight:
            maxX = max(nx, minX + minSize)
            minY = min(ny, maxY - minSize)
        case .bottomLeft:
            minX = min(nx, maxX - minSize)
            maxY = max(ny, minY + minSize)
        case .bottomRight:
            maxX = max(nx, minX + minSize)
            maxY = max(ny, minY + minSize)
        }
        rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func pixelRect(_ r: CGRect, in content: CGRect) -> CGRect {
        CGRect(x: content.minX + r.minX * content.width,
               y: content.minY + r.minY * content.height,
               width: r.width * content.width,
               height: r.height * content.height)
    }

    /// The rect `.scaledToFit()` actually paints the image into, given letterboxing.
    private static func contentRect(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
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

    // Crop
    @State private var cropMode = false
    @State private var cropDraft = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cropBase: UIImage?

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
                if cropMode {
                    cropControlRow
                } else {
                    sliderRow
                    toolStrip
                    actionRow
                }
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
                        .disabled(original == nil || cropMode)
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

            if cropMode, let base = cropBase {
                CropOverlay(rect: $cropDraft, imageSize: base.size)
                    .background(
                        Image(uiImage: base)
                            .resizable()
                            .scaledToFit()
                    )
            } else if let shown = showingOriginal ? proxy : (rendered ?? proxy) {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }

            if showingOriginal && !cropMode {
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

            // Note/error live as an overlay pinned to the bottom of the image
            // instead of extra rows in the outer VStack. Previously they were
            // separate rows, so the image area shrank whenever a note appeared
            // after an edit — the photo displayed at a different size before
            // and after editing. Overlaying keeps imageArea's frame constant.
            if !cropMode {
                VStack(spacing: 8) {
                    Spacer()
                    if let note = aiNote { aiNoteBar(note) }
                    if let err = aiError { errorBar(err) }
                }
                .padding(.bottom, 10)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Press and hold anywhere on the photo to compare against the original.
        // This uses a raw touch-down/touch-up drag gesture rather than
        // onLongPressGesture: once onLongPressGesture's minimumDuration elapses
        // it considers itself "done" and resets `pressing` back to false
        // immediately — before the finger actually lifts — which made the
        // comparison flash for an instant and revert while still held.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !cropMode else { return }
                    if !showingOriginal { showingOriginal = true }
                }
                .onEnded { _ in
                    showingOriginal = false
                }
        )
    }

    private var cropControlRow: some View {
        HStack(spacing: 10) {
            Button {
                cropMode = false
                cropBase = nil
            } label: {
                Text("Cancel")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            Button {
                cropDraft = CGRect(x: 0, y: 0, width: 1, height: 1)
            } label: {
                Text("Reset")
                    .font(.subheadline)
                    .frame(width: 80)
                    .frame(height: 40)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            Button {
                adj.cropRect = cropDraft
                cropMode = false
                cropBase = nil
                render()
            } label: {
                Text("Apply")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .foregroundColor(.black)
                    .background(cyan, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
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
                enterCropMode()
            } label: {
                Image(systemName: "crop")
                    .frame(width: 44, height: 40)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
            .disabled(proxy == nil)

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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 18)
    }

    private func errorBar(_ msg: String) -> some View {
        Text(msg)
            .font(.caption)
            .foregroundColor(.orange)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 18)
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

    /// Seeds the crop overlay with an orientation-corrected but *un-cropped*
    /// view of the proxy, so the user can always see (and re-adjust) the full
    /// frame — including expanding a crop back out — regardless of the
    /// currently applied crop.
    private func enterCropMode() {
        guard let proxy else { return }
        let orientationOnly = EditAdjustments(rotationQuarters: adj.rotationQuarters, flipH: adj.flipH)
        cropBase = ImagePipeline.apply(orientationOnly, to: proxy)
        cropDraft = adj.cropRect
        cropMode = true
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

    /// The suggestion already stored for this photo, if any. Read fresh from the
    /// store rather than the `entry` copy this view was created with.
    private var cachedSuggestion: (adjustments: EditAdjustments, note: String,
                                   crop: CGRect?, cropNote: String?)? {
        guard let fresh = PhotoStore.shared.entries.first(where: { $0.id == entry.id }),
              let a = fresh.aiAdjustments else { return nil }
        return (a, fresh.aiAdjustNote ?? "Reapplied the saved AI correction.",
                fresh.aiCropRect, fresh.aiCropNote)
    }

    /// Lands a suggestion on the sliders.
    ///
    /// The AI only ever reasons about tone and framing, so the user's own
    /// orientation choices are carried across rather than reset — assigning the
    /// suggestion wholesale would otherwise silently undo a rotate or flip, since
    /// `AdjustService` builds its result from a neutral `EditAdjustments()`.
    ///
    /// The crop is the one value the AI is allowed to overwrite. It arrives in the
    /// un-oriented analysis frame and is mapped into the current oriented frame; if
    /// no crop was suggested, whatever the user had cropped is left alone.
    private func applySuggestion(_ adjustments: EditAdjustments,
                                 note: String,
                                 crop: CGRect?,
                                 cropNote: String?) {
        let keepCrop = adj.cropRect
        let quarters = adj.rotationQuarters
        let flipH = adj.flipH
        withAnimation {
            adj = adjustments
            adj.rotationQuarters = quarters
            adj.flipH = flipH
            adj.cropRect = crop.map {
                ImagePipeline.orientedCropRect($0, quarters: quarters, flipH: flipH)
            } ?? keepCrop
            aiNote = [note, cropNote].compactMap { $0 }.joined(separator: " ")
        }
        render()
    }

    private func aiAdjust() {
        // Already analysed this photo — reapply for free. Reset clears the sliders
        // but never the cache, so Reset → AI adjust costs nothing. The cache is
        // only discarded when the image itself is edited and saved.
        if let cached = cachedSuggestion {
            aiError = nil
            applySuggestion(cached.adjustments, note: cached.note,
                            crop: cached.crop, cropNote: cached.cropNote)
            Haptics.tap()
            return
        }

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
                    applySuggestion(result.adjustments, note: result.note,
                                    crop: result.suggestedCrop, cropNote: result.cropNote)
                    tokenManager.useEvalToken()
                    PhotoStore.shared.attachAIAdjustments(result.adjustments,
                                                          note: result.note,
                                                          cropRect: result.suggestedCrop,
                                                          cropNote: result.cropNote,
                                                          to: entry.id)
                    aiLoading = false
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
