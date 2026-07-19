import Vision
import CoreVideo
import CoreGraphics
import Combine
import UIKit

struct SubjectObservation: Equatable {
    /// Normalized rect, top-left origin (SwiftUI coordinate space)
    let box: CGRect
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

/// Detects the main subject, then LOCKS ON with a real object tracker so the box
/// follows that same subject across the frame while you recompose.
final class SubjectDetector: ObservableObject {
    @Published var subject: SubjectObservation?
    @Published var brightness: Double = 0.5
    @Published var faceCount: Int = 0
    /// Normalized tap point (top-left origin). When set, selection anchors to it.
    @Published var selectedPoint: CGPoint?

    private let queue = DispatchQueue(label: "apollocam.vision", qos: .userInitiated)

    // Tracking state (Vision coordinates: bottom-left origin)
    private var trackedObservation: VNDetectedObjectObservation?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackLostFrames = 0
    private var framesSinceReseed = 0

    // Smoothing state (top-left coords)
    private var smoothedBox: CGRect?
    private var candidateBox: CGRect?
    private var candidateStreak = 0
    private var missStreak = 0
    private var pendingAnchor: CGPoint?

    func clearSelection() {
        queue.async { [weak self] in
            guard let self else { return }
            self.trackedObservation = nil
            self.sequenceHandler = VNSequenceRequestHandler()
            self.pendingAnchor = nil
            DispatchQueue.main.async { self.selectedPoint = nil }
        }
    }

    func select(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self else { return }
            // Drop the current lock and re-seed from whatever is at the tapped point
            self.trackedObservation = nil
            self.sequenceHandler = VNSequenceRequestHandler()
            self.pendingAnchor = point
            DispatchQueue.main.async { self.selectedPoint = point }
        }
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            guard let self else { return }

            let bright = Self.averageBrightness(pixelBuffer)

            var resultTopLeft: CGRect?
            var faces = 0

            if let tracked = self.trackedObservation {
                // TRACKING MODE: follow the locked subject
                let request = VNTrackObjectRequest(detectedObjectObservation: tracked)
                request.trackingLevel = .accurate
                do {
                    try self.sequenceHandler.perform([request], on: pixelBuffer, orientation: .right)
                    self.framesSinceReseed += 1
                    if let r = request.results?.first as? VNDetectedObjectObservation, r.confidence > 0.25 {
                        self.trackedObservation = r
                        self.trackLostFrames = 0
                        let b = r.boundingBox
                        resultTopLeft = CGRect(x: b.origin.x, y: 1 - b.origin.y - b.height, width: b.width, height: b.height)
                    } else {
                        self.trackLostFrames += 1
                    }
                } catch {
                    // Sequence handlers cap out after long tracks — reset and re-detect
                    self.trackLostFrames = 99
                }

                // Lost it for ~2s (8 frames at 4fps) → back to searching
                if self.trackLostFrames > 8 || self.framesSinceReseed > 400 {
                    self.trackedObservation = nil
                    self.sequenceHandler = VNSequenceRequestHandler()
                }

                // Cheap face count for scene detection every few frames
                let faceReq = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right).perform([faceReq])
                faces = faceReq.results?.count ?? 0
            } else {
                // SEARCH MODE: detect, then seed the tracker
                let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
                let faceReq = VNDetectFaceRectanglesRequest()
                let animals = VNRecognizeAnimalsRequest()
                try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
                    .perform([saliency, faceReq, animals])

                faces = faceReq.results?.count ?? 0

                // Candidates in Vision coords (bottom-left)
                var vision: [CGRect] = []
                if let f = faceReq.results, !f.isEmpty {
                    vision = f.map { $0.boundingBox }
                } else if let a = animals.results, !a.isEmpty {
                    vision = a.map { $0.boundingBox }
                } else if let s = saliency.results?.first?.salientObjects {
                    vision = s.map { $0.boundingBox }
                }

                let chosenVision: CGRect?
                if let anchor = self.pendingAnchor {
                    // Anchor is top-left; convert candidates for distance test
                    let anchored = vision.min(by: {
                        let ca = CGPoint(x: $0.midX, y: 1 - $0.midY)
                        let cb = CGPoint(x: $1.midX, y: 1 - $1.midY)
                        return Self.dist(ca, anchor) < Self.dist(cb, anchor)
                    })
                    if let a = anchored {
                        let c = CGPoint(x: a.midX, y: 1 - a.midY)
                        chosenVision = Self.dist(c, anchor) < 0.35 ? a : nil
                    } else { chosenVision = nil }
                } else {
                    chosenVision = vision.max(by: { $0.width * $0.height < $1.width * $1.height })
                }

                if let cv = chosenVision {
                    // Seed the tracker with this subject
                    self.trackedObservation = VNDetectedObjectObservation(boundingBox: cv)
                    self.trackLostFrames = 0
                    self.framesSinceReseed = 0
                    self.pendingAnchor = nil
                    resultTopLeft = CGRect(x: cv.origin.x, y: 1 - cv.origin.y - cv.height, width: cv.width, height: cv.height)
                }
            }

            let smoothed = self.smooth(resultTopLeft)

            DispatchQueue.main.async {
                self.brightness = bright
                self.faceCount = faces
                self.subject = smoothed.map { SubjectObservation(box: $0) }
            }
        }
    }

    /// Glide the displayed box toward the tracked position; brief losses don't blink it out.
    private func smooth(_ raw: CGRect?) -> CGRect? {
        guard let raw else {
            missStreak += 1
            if missStreak > 5 {
                smoothedBox = nil
            }
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

// MARK: - Scene detection (pure heuristics, zero cost)

enum SceneDetector {
    static func detect(subject: SubjectObservation?, faceCount: Int, brightness: Double) -> SceneKind {
        if faceCount >= 2 { return .street }
        if let s = subject {
            if s.area > 0.5 { return .macro }
            if faceCount == 1 && s.area > 0.12 { return .portrait }
            if s.area < 0.07 { return .landscape }
        } else {
            return .landscape
        }
        return .general
    }
}

// MARK: - Guidance engine (on-device, free)

struct Guidance {
    let message: String
    let tip: String?
    let aligned: Bool
    let suggestedRule: CompositionRule
    let scene: SceneKind
}

enum GuidanceEngine {
    static func evaluate(subject: SubjectObservation?, faceCount: Int, rule: CompositionRule?, brightness: Double, viewSize: CGSize) -> Guidance {
        let scene = SceneDetector.detect(subject: subject, faceCount: faceCount, brightness: brightness)

        guard let subject else {
            return Guidance(
                message: "Point at your subject, or tap to select it",
                tip: passiveTip(subject: nil, scene: scene, brightness: brightness),
                aligned: false,
                suggestedRule: rule ?? suggestRule(for: nil, scene: scene),
                scene: scene)
        }

        let suggested = rule ?? suggestRule(for: subject, scene: scene)
        let subjectPx = CGPoint(x: subject.center.x * viewSize.width, y: subject.center.y * viewSize.height)
        let targets = suggested.targetPoints(in: viewSize)
        let nearest = targets.min(by: { $0.distance(to: subjectPx) < $1.distance(to: subjectPx) }) ?? subjectPx
        let dist = nearest.distance(to: subjectPx)
        let threshold = min(viewSize.width, viewSize.height) * 0.06

        let tip = passiveTip(subject: subject, scene: scene, brightness: brightness)

        if dist < threshold {
            return Guidance(message: "Subject aligned", tip: tip, aligned: true, suggestedRule: suggested, scene: scene)
        }

        let dx = nearest.x - subjectPx.x
        let dy = nearest.y - subjectPx.y
        var directions: [String] = []
        if abs(dx) > threshold { directions.append(dx > 0 ? "right" : "left") }
        if abs(dy) > threshold { directions.append(dy > 0 ? "down" : "up") }
        let msg = directions.isEmpty ? "Almost there" : "Frame subject \(directions.joined(separator: " and "))"

        return Guidance(message: msg, tip: tip, aligned: false, suggestedRule: suggested, scene: scene)
    }

    /// Free, on-device shooting tips from simple heuristics. One at a time, priority-ordered.
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
