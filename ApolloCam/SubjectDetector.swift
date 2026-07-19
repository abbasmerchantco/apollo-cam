import Vision
import CoreVideo
import CoreGraphics
import Combine
import UIKit

struct SubjectObservation: Equatable {
    /// Normalized rect, top-left origin (SwiftUI coordinate space)
    let box: CGRect
    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// Detects and smoothly tracks the main subject.
/// - Auto mode: faces > animals > salient objects, with temporal smoothing so the box glides instead of jumping.
/// - Tap mode: the user taps a point; detection locks to whatever is at/near that point until cleared.
final class SubjectDetector: ObservableObject {
    @Published var subject: SubjectObservation?
    @Published var brightness: Double = 0.5
    /// Normalized tap point (top-left origin). When set, subject selection anchors to it.
    @Published var selectedPoint: CGPoint?

    private let queue = DispatchQueue(label: "apollocam.vision", qos: .userInitiated)

    // Temporal smoothing state
    private var smoothedBox: CGRect?
    private var candidateBox: CGRect?
    private var candidateStreak = 0
    private var missStreak = 0

    func clearSelection() {
        selectedPoint = nil
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) {
        // Read selection on whatever thread; CGPoint is a value type
        let anchor = selectedPoint

        queue.async { [weak self] in
            guard let self else { return }

            let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            let animals = VNRecognizeAnimalsRequest()

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            try? handler.perform([saliency, faces, animals])

            // Collect every candidate box (normalized, bottom-left origin from Vision)
            var candidates: [CGRect] = []
            if let f = faces.results { candidates += f.map { $0.boundingBox } }
            if let a = animals.results { candidates += a.map { $0.boundingBox } }
            if let s = saliency.results?.first?.salientObjects { candidates += s.map { $0.boundingBox } }

            // Convert to top-left origin
            let topLeft: [CGRect] = candidates.map {
                CGRect(x: $0.origin.x, y: 1 - $0.origin.y - $0.height, width: $0.width, height: $0.height)
            }

            let chosen: CGRect?
            if let anchor {
                // Locked mode: prefer a box containing the tap; else nearest within reach
                if let containing = topLeft.filter({ $0.insetBy(dx: -0.03, dy: -0.03).contains(anchor) })
                    .max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    chosen = containing
                } else {
                    let nearest = topLeft.min(by: {
                        Self.dist(CGPoint(x: $0.midX, y: $0.midY), anchor) < Self.dist(CGPoint(x: $1.midX, y: $1.midY), anchor)
                    })
                    if let n = nearest, Self.dist(CGPoint(x: n.midX, y: n.midY), anchor) < 0.3 {
                        chosen = n
                    } else {
                        // Nothing near the tap this frame — keep last known box briefly
                        chosen = nil
                    }
                }
            } else {
                // Auto mode: faces beat animals beat saliency (order preserved above), pick largest of the first type present
                if let f = faces.results, !f.isEmpty {
                    chosen = f.map { CGRect(x: $0.boundingBox.origin.x, y: 1 - $0.boundingBox.origin.y - $0.boundingBox.height, width: $0.boundingBox.width, height: $0.boundingBox.height) }
                        .max(by: { $0.width * $0.height < $1.width * $1.height })
                } else if let a = animals.results, !a.isEmpty {
                    chosen = a.map { CGRect(x: $0.boundingBox.origin.x, y: 1 - $0.boundingBox.origin.y - $0.boundingBox.height, width: $0.boundingBox.width, height: $0.boundingBox.height) }
                        .max(by: { $0.width * $0.height < $1.width * $1.height })
                } else {
                    chosen = topLeft.max(by: { $0.width * $0.height < $1.width * $1.height })
                }
            }

            let bright = Self.averageBrightness(pixelBuffer)
            let smoothed = self.smooth(chosen)

            DispatchQueue.main.async {
                self.brightness = bright
                self.subject = smoothed.map { SubjectObservation(box: $0) }
            }
        }
    }

    /// Temporal smoothing:
    /// - New subjects must persist 3 consecutive frames before we switch to them (kills flicker).
    /// - The displayed box eases toward the target (glide, not teleport).
    /// - Lost subjects linger 4 frames before disappearing (kills blink-outs).
    private func smooth(_ raw: CGRect?) -> CGRect? {
        guard let raw else {
            missStreak += 1
            if missStreak > 4 {
                smoothedBox = nil
                candidateBox = nil
                candidateStreak = 0
            }
            return smoothedBox
        }
        missStreak = 0

        guard let current = smoothedBox else {
            // First detection: require a short streak before showing
            if let cand = candidateBox, Self.iou(cand, raw) > 0.3 {
                candidateStreak += 1
            } else {
                candidateBox = raw
                candidateStreak = 1
            }
            if candidateStreak >= 2 {
                smoothedBox = raw
                candidateBox = nil
                candidateStreak = 0
            }
            return smoothedBox
        }

        if Self.iou(current, raw) > 0.15 {
            // Same subject: ease toward it
            smoothedBox = Self.lerp(current, raw, 0.35)
            candidateBox = nil
            candidateStreak = 0
        } else {
            // Different subject: only switch after it persists
            if let cand = candidateBox, Self.iou(cand, raw) > 0.3 {
                candidateStreak += 1
            } else {
                candidateBox = raw
                candidateStreak = 1
            }
            if candidateStreak >= 3 {
                smoothedBox = raw
                candidateBox = nil
                candidateStreak = 0
            }
        }
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

// MARK: - Guidance engine (on-device, free)

struct Guidance {
    let message: String
    let aligned: Bool
    let suggestedRule: CompositionRule
}

enum GuidanceEngine {
    static func evaluate(subject: SubjectObservation?, rule: CompositionRule?, brightness: Double, viewSize: CGSize) -> Guidance {
        guard let subject else {
            return Guidance(message: "Point at your subject, or tap to select it", aligned: false, suggestedRule: rule ?? .ruleOfThirds)
        }

        let suggested = rule ?? suggestRule(for: subject)
        let subjectPx = CGPoint(x: subject.center.x * viewSize.width, y: subject.center.y * viewSize.height)
        let targets = suggested.targetPoints(in: viewSize)
        let nearest = targets.min(by: { $0.distance(to: subjectPx) < $1.distance(to: subjectPx) }) ?? subjectPx
        let dist = nearest.distance(to: subjectPx)
        let threshold = min(viewSize.width, viewSize.height) * 0.06

        if dist < threshold {
            return Guidance(message: "Subject aligned", aligned: true, suggestedRule: suggested)
        }

        let dx = nearest.x - subjectPx.x
        let dy = nearest.y - subjectPx.y
        var directions: [String] = []
        if abs(dx) > threshold { directions.append(dx > 0 ? "right" : "left") }
        if abs(dy) > threshold { directions.append(dy > 0 ? "down" : "up") }

        var msg = directions.isEmpty ? "Almost there" : "Frame subject \(directions.joined(separator: " and "))"
        if brightness < 0.18 { msg += " · dark scene" }
        else if brightness > 0.85 { msg += " · very bright" }

        return Guidance(message: msg, aligned: false, suggestedRule: suggested)
    }

    static func suggestRule(for subject: SubjectObservation) -> CompositionRule {
        let box = subject.box
        if box.width * box.height > 0.35 { return .centeredCircle }
        if abs(box.midX - 0.5) < 0.08 && box.width > 0.5 { return .symmetry }
        if box.maxY > 0.75 && box.height < 0.35 { return .foregroundInterest }
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
    static func alignedPing() {
        generator.notificationOccurred(.success)
    }
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
