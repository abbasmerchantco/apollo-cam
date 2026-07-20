import Vision
import CoreVideo
import CoreGraphics
import Combine
import UIKit

struct SubjectObservation: Equatable {
    /// Normalized rect, top-left origin (SwiftUI coordinate space)
    let box: CGRect
    let label: String?
    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
    var area: CGFloat { box.width * box.height }
}

enum SceneKind: String {
    case portrait = "Portrait"
    case landscape = "Landscape"
    case macro = "Close-up"
    case street = "Street"
    case general = ""
}

private struct Detection {
    let box: CGRect       // top-left origin, normalized
    let label: String?
    let confidence: Float
}

/// GudoCam-style pipeline:
///  1. YOLOv8n (your model) detects people/animals/objects each frame — falls back to
///     Vision faces/animals/saliency until the model is dropped in.
///  2. Identity association: the locked subject is matched frame-to-frame by overlap,
///     so the box follows the SAME subject while you recompose.
///  3. CompositionModel (your model) classifies the framing into one of the 14 types —
///     falls back to scene heuristics until dropped in.
final class SubjectDetector: ObservableObject {
    @Published var subject: SubjectObservation?
    @Published var brightness: Double = 0.5
    @Published var personCount: Int = 0
    @Published var selectedPoint: CGPoint?
    /// Composition predicted by the CompositionModel (nil = model absent or unsure)
    @Published var modelRule: CompositionRule?
    @Published var modelRuleConfidence: Double = 0

    private let queue = DispatchQueue(label: "apollocam.vision", qos: .userInitiated)

    // Identity lock (top-left coords)
    private var lockedBox: CGRect?
    private var coastFrames = 0
    private var pendingAnchor: CGPoint?

    // Smoothing
    private var smoothedBox: CGRect?

    // Composition classification throttle
    private var framesSinceClassify = 99

    func clearSelection() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingAnchor = nil
            self.lockedBox = nil
            DispatchQueue.main.async { self.selectedPoint = nil }
        }
    }

    func select(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingAnchor = point
            self.lockedBox = nil
            DispatchQueue.main.async { self.selectedPoint = point }
        }
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            guard let self else { return }

            let bright = Self.averageBrightness(pixelBuffer)
            let detections = self.detect(pixelBuffer)
            let people = detections.filter { ($0.label ?? "").lowercased().contains("person") }.count
                + (MLModels.shared.yoloAvailable ? 0 : detections.filter { $0.label == "face" }.count)

            // ---- Identity association ----
            var chosen: Detection?
            if let anchor = self.pendingAnchor {
                chosen = detections
                    .filter { Self.dist(CGPoint(x: $0.box.midX, y: $0.box.midY), anchor) < 0.35 || $0.box.insetBy(dx: -0.03, dy: -0.03).contains(anchor) }
                    .max(by: { $0.confidence < $1.confidence })
                if chosen != nil { self.pendingAnchor = nil }
            } else if let locked = self.lockedBox {
                chosen = detections
                    .map { ($0, Self.iou($0.box, locked)) }
                    .filter { $0.1 > 0.05 }
                    .max(by: { $0.1 < $1.1 })?.0
            } else {
                chosen = detections.max(by: { score($0) < score($1) })
            }

            func score(_ d: Detection) -> Float {
                var s = d.confidence * Float(d.box.width * d.box.height + 0.15)
                if let l = d.label?.lowercased(), l.contains("person") || l == "face" { s *= 2.2 }
                return s
            }

            if let c = chosen {
                self.lockedBox = c.box
                self.coastFrames = 0
            } else if self.lockedBox != nil {
                // Coast briefly through missed detections, then release
                self.coastFrames += 1
                if self.coastFrames > 6 { self.lockedBox = nil }
            }

            let smoothed = self.smooth(self.lockedBox)
            let label = chosen?.label

            // ---- Composition classification (~1x/sec) ----
            self.framesSinceClassify += 1
            var newRule: CompositionRule? = nil
            var newConf: Double = 0
            var classified = false
            if self.framesSinceClassify >= 4, let comp = MLModels.shared.composition {
                classified = true
                self.framesSinceClassify = 0
                let req = VNCoreMLRequest(model: comp)
                req.imageCropAndScaleOption = .scaleFill
                try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([req])
                if let top = (req.results as? [VNClassificationObservation])?.first,
                   top.confidence > 0.35,
                   let rule = MLModels.rule(fromLabel: top.identifier) {
                    newRule = rule
                    newConf = Double(top.confidence)
                }
            }

            DispatchQueue.main.async {
                self.brightness = bright
                self.personCount = people
                self.subject = smoothed.map { SubjectObservation(box: $0, label: label) }
                if classified {
                    self.modelRule = newRule
                    self.modelRuleConfidence = newConf
                }
            }
        }
    }

    // MARK: - Detection (YOLO first, Vision fallback)

    private func detect(_ pixelBuffer: CVPixelBuffer) -> [Detection] {
        if let yolo = MLModels.shared.yolo {
            let request = VNCoreMLRequest(model: yolo)
            request.imageCropAndScaleOption = .scaleFill
            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([request])
            if let results = request.results as? [VNRecognizedObjectObservation] {
                return results.compactMap { obs in
                    guard obs.confidence > 0.35 else { return nil }
                    let b = obs.boundingBox
                    return Detection(
                        box: CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height, width: b.width, height: b.height),
                        label: obs.labels.first?.identifier,
                        confidence: obs.confidence)
                }
            }
            return []
        }

        // Fallback: faces > animals > saliency
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            .perform([saliency, faces, animals])

        var out: [Detection] = []
        for f in faces.results ?? [] {
            let b = f.boundingBox
            out.append(Detection(box: CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height, width: b.width, height: b.height),
                                 label: "face", confidence: f.confidence))
        }
        for a in animals.results ?? [] {
            let b = a.boundingBox
            out.append(Detection(box: CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height, width: b.width, height: b.height),
                                 label: a.labels.first?.identifier ?? "animal", confidence: a.confidence))
        }
        for s in saliency.results?.first?.salientObjects ?? [] {
            let b = s.boundingBox
            out.append(Detection(box: CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height, width: b.width, height: b.height),
                                 label: nil, confidence: s.confidence))
        }
        return out
    }

    // MARK: - Smoothing

    private var missStreak = 0
    private func smooth(_ raw: CGRect?) -> CGRect? {
        guard let raw else {
            missStreak += 1
            if missStreak > 5 { smoothedBox = nil }
            return smoothedBox
        }
        missStreak = 0
        guard let current = smoothedBox else {
            smoothedBox = raw
            return smoothedBox
        }
        smoothedBox = Self.lerp(current, raw, 0.45)
        return smoothedBox
    }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.origin.x + (b.origin.x - a.origin.x) * t,
               y: a.origin.y + (b.origin.y - a.origin.y) * t,
               width: a.width + (b.width - a.width) * t,
               height: a.height + (b.height - a.height) * t)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let i = inter.width * inter.height
        let u = a.width * a.height + b.width * b.height - i
        return u > 0 ? i / u : 0
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    private static func averageBrightness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var total = 0, samples = 0
        let step = max(1, width / 32)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let o = y * stride + x * 4
                total += (Int(ptr[o]) + Int(ptr[o + 1]) + Int(ptr[o + 2])) / 3
                samples += 1
                x += step
            }
            y += step
        }
        return samples > 0 ? Double(total) / Double(samples) / 255.0 : 0.5
    }
}

// MARK: - Scene detection (free heuristics)

enum SceneDetector {
    static func detect(subject: SubjectObservation?, personCount: Int, brightness: Double) -> SceneKind {
        if personCount >= 2 { return .street }
        if let s = subject {
            if s.area > 0.5 { return .macro }
            let isPerson = (s.label ?? "").lowercased().contains("person") || s.label == "face"
            if (personCount == 1 || isPerson) && s.area > 0.12 { return .portrait }
            if s.area < 0.07 { return .landscape }
        } else {
            return .landscape
        }
        return .general
    }
}

// MARK: - Guidance engine

struct Guidance {
    let message: String
    let tip: String?
    let aligned: Bool
    let suggestedRule: CompositionRule
    let ruleFromModel: Bool
    let scene: SceneKind
}

enum GuidanceEngine {
    static func evaluate(subject: SubjectObservation?, personCount: Int, modelRule: CompositionRule?,
                         rule: CompositionRule?, brightness: Double, viewSize: CGSize) -> Guidance {
        let scene = SceneDetector.detect(subject: subject, personCount: personCount, brightness: brightness)

        // Priority: manual override > CompositionModel prediction > heuristics
        let suggested: CompositionRule
        let fromModel: Bool
        if let rule {
            suggested = rule; fromModel = false
        } else if let modelRule {
            suggested = modelRule; fromModel = true
        } else {
            suggested = suggestRule(for: subject, scene: scene); fromModel = false
        }

        let tip = passiveTip(subject: subject, scene: scene, brightness: brightness)

        guard let subject else {
            return Guidance(message: "Point at your subject, or tap to select it",
                            tip: tip, aligned: false, suggestedRule: suggested, ruleFromModel: fromModel, scene: scene)
        }

        let subjectPx = CGPoint(x: subject.center.x * viewSize.width, y: subject.center.y * viewSize.height)
        let targets = suggested.targetPoints(in: viewSize)
        let nearest = targets.min(by: { $0.distance(to: subjectPx) < $1.distance(to: subjectPx) }) ?? subjectPx
        let dist = nearest.distance(to: subjectPx)
        let threshold = min(viewSize.width, viewSize.height) * 0.06

        if dist < threshold {
            return Guidance(message: "Subject aligned", tip: tip, aligned: true,
                            suggestedRule: suggested, ruleFromModel: fromModel, scene: scene)
        }

        let dx = nearest.x - subjectPx.x
        let dy = nearest.y - subjectPx.y
        var directions: [String] = []
        if abs(dx) > threshold { directions.append(dx > 0 ? "right" : "left") }
        if abs(dy) > threshold { directions.append(dy > 0 ? "down" : "up") }
        let msg = directions.isEmpty ? "Almost there" : "Frame subject \(directions.joined(separator: " and "))"

        return Guidance(message: msg, tip: tip, aligned: false,
                        suggestedRule: suggested, ruleFromModel: fromModel, scene: scene)
    }

    static func passiveTip(subject: SubjectObservation?, scene: SceneKind, brightness: Double) -> String? {
        if brightness < 0.15 { return "Very dark — find more light or brace the phone" }
        if brightness > 0.88 { return "Very bright — angle away from the light source" }
        if let s = subject {
            if s.area < 0.04 { return "Subject is tiny — step closer or zoom in" }
            if s.area > 0.75 { return "Very tight — step back for breathing room" }
            let edge: CGFloat = 0.07
            if s.box.minX < edge || s.box.maxX > 1 - edge || s.box.minY < edge || s.box.maxY > 1 - edge {
                return "Subject is clipped — give it space from the edges"
            }
        }
        switch scene {
        case .landscape: return "Add foreground interest for depth"
        case .portrait: return brightness < 0.45 ? "Turn your subject toward the light" : nil
        case .street: return "Watch the layers — separate people from background"
        case .macro: return "Hold very still — close shots amplify shake"
        case .general: return nil
        }
    }

    static func suggestRule(for subject: SubjectObservation?, scene: SceneKind) -> CompositionRule {
        switch scene {
        case .macro: return .centeredCircle
        case .landscape: return .layering
        case .street: return .leadingLines
        case .portrait: return .ruleOfThirds
        case .general: break
        }
        guard let s = subject else { return .ruleOfThirds }
        if s.area > 0.35 { return .centeredCircle }
        if abs(s.box.midX - 0.5) < 0.08 && s.box.width > 0.5 { return .symmetry }
        return .ruleOfThirds
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat {
        sqrt(pow(x - p.x, 2) + pow(y - p.y, 2))
    }
}

enum Haptics {
    private static let generator = UINotificationFeedbackGenerator()
    static func alignedPing() { generator.notificationOccurred(.success) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
