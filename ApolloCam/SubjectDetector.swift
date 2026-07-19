import Vision
import CoreVideo
import CoreGraphics
import Combine
import UIKit

struct SubjectObservation {
    /// Normalized rect, top-left origin (SwiftUI coordinate space)
    let box: CGRect
    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// Detects the main subject each frame using Vision's objectness saliency
/// (finds the "thing that draws the eye" — people, animals, objects — with no bundled model),
/// plus face/animal detectors for higher-confidence subjects when present.
final class SubjectDetector: ObservableObject {
    @Published var subject: SubjectObservation?
    @Published var brightness: Double = 0.5

    private let queue = DispatchQueue(label: "apollocam.vision", qos: .userInitiated)

    func analyze(_ pixelBuffer: CVPixelBuffer) {
        queue.async { [weak self] in
            guard let self else { return }

            let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
            let faces = VNDetectFaceRectanglesRequest()
            let animals = VNRecognizeAnimalsRequest()

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            try? handler.perform([saliency, faces, animals])

            var best: CGRect?

            // Priority: faces > animals > salient objects
            if let face = (faces.results)?.max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
                best = face.boundingBox
            } else if let animal = (animals.results)?.max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
                best = animal.boundingBox
            } else if let salient = (saliency.results?.first)?.salientObjects?.max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
                best = salient.boundingBox
            }

            let bright = Self.averageBrightness(pixelBuffer)

            DispatchQueue.main.async {
                self.brightness = bright
                if let b = best {
                    // Vision: bottom-left origin → SwiftUI: top-left origin
                    self.subject = SubjectObservation(box: CGRect(
                        x: b.origin.x,
                        y: 1 - b.origin.y - b.height,
                        width: b.width,
                        height: b.height))
                } else {
                    self.subject = nil
                }
            }
        }
    }

    private static func averageBrightness(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0.5 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var total: Int = 0, samples: Int = 0
        let step = max(1, width / 40)
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                let o = y * stride + x * 4
                total += (Int(ptr[o]) + Int(ptr[o + 1]) + Int(ptr[o + 2])) / 3
                samples += 1
            }
        }
        return samples > 0 ? Double(total) / Double(samples) / 255.0 : 0.5
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

// MARK: - Guidance engine

struct Guidance {
    let message: String
    let aligned: Bool
    let suggestedRule: CompositionRule
}

enum GuidanceEngine {
    /// Pick the best-fit rule from the subject's shape and position, then tell the user how to align.
    static func evaluate(subject: SubjectObservation?, rule: CompositionRule?, brightness: Double, viewSize: CGSize) -> Guidance {
        guard let subject else {
            return Guidance(message: "Looking for a subject…", aligned: false, suggestedRule: rule ?? .ruleOfThirds)
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

        var msg = directions.isEmpty ? "Almost there — tiny adjustment" : "Move subject \(directions.joined(separator: " and "))"

        if brightness < 0.18 { msg += " · scene is dark, add light" }
        else if brightness > 0.85 { msg += " · very bright, lower exposure" }

        return Guidance(message: msg, aligned: false, suggestedRule: suggested)
    }

    static func suggestRule(for subject: SubjectObservation) -> CompositionRule {
        let box = subject.box
        // Large centered subject → centered circle; wide subject → symmetry; small subject → thirds
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

// MARK: - Haptics

enum Haptics {
    private static let generator = UINotificationFeedbackGenerator()
    static func alignedPing() {
        generator.notificationOccurred(.success)
    }
}
