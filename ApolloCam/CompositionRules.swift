import SwiftUI

enum CompositionRule: String, CaseIterable, Identifiable, Codable {
    case ruleOfThirds = "Rule of thirds"
    case goldenRatio = "Golden ratio"
    case centeredCircle = "Centered circle"
    case diagonal = "Diagonal"
    case symmetry = "Symmetry"
    case leadingLines = "Leading lines"
    case frameWithinFrame = "Frame within frame"
    case foregroundInterest = "Foreground interest"
    case layering = "Layering"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ruleOfThirds: return "grid"
        case .goldenRatio: return "hurricane"
        case .centeredCircle: return "circle.dashed"
        case .diagonal: return "line.diagonal"
        case .symmetry: return "rectangle.split.2x1"
        case .leadingLines: return "arrow.up.forward"
        case .frameWithinFrame: return "rectangle.inset.filled"
        case .foregroundInterest: return "square.stack.3d.down.forward"
        case .layering: return "square.3.layers.3d"
        }
    }

    /// Target points (normalized 0-1, top-left origin) where the main subject should sit.
    func targetPoints(in size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height
        switch self {
        case .ruleOfThirds:
            return [
                CGPoint(x: w / 3, y: h / 3), CGPoint(x: 2 * w / 3, y: h / 3),
                CGPoint(x: w / 3, y: 2 * h / 3), CGPoint(x: 2 * w / 3, y: 2 * h / 3)
            ]
        case .goldenRatio:
            let phi: CGFloat = 0.618
            return [
                CGPoint(x: w * (1 - phi), y: h * (1 - phi)), CGPoint(x: w * phi, y: h * (1 - phi)),
                CGPoint(x: w * (1 - phi), y: h * phi), CGPoint(x: w * phi, y: h * phi)
            ]
        case .centeredCircle, .symmetry, .frameWithinFrame:
            return [CGPoint(x: w / 2, y: h / 2)]
        case .diagonal:
            return [CGPoint(x: w * 0.25, y: h * 0.25), CGPoint(x: w * 0.75, y: h * 0.75),
                    CGPoint(x: w * 0.75, y: h * 0.25), CGPoint(x: w * 0.25, y: h * 0.75)]
        case .leadingLines:
            return [CGPoint(x: w / 2, y: h * 0.4)]
        case .foregroundInterest:
            return [CGPoint(x: w / 2, y: h * 0.72)]
        case .layering:
            return [CGPoint(x: w / 3, y: h * 0.55), CGPoint(x: 2 * w / 3, y: h * 0.55)]
        }
    }

    var hint: String {
        switch self {
        case .ruleOfThirds: return "Place your subject on a gridline intersection"
        case .goldenRatio: return "Align your subject with a golden point"
        case .centeredCircle: return "Center your subject inside the circle"
        case .diagonal: return "Position your subject along the diagonal"
        case .symmetry: return "Center the scene on the vertical axis"
        case .leadingLines: return "Angle lines so they converge on the subject"
        case .frameWithinFrame: return "Use a doorway, arch, or gap to frame the subject"
        case .foregroundInterest: return "Keep something interesting in the lower third"
        case .layering: return "Stack foreground, midground, and background"
        }
    }
}

/// Overlay shape drawing for each composition rule.
struct CompositionOverlay: View {
    let rule: CompositionRule
    let aligned: Bool

    private var lineColor: Color {
        aligned ? Color.green.opacity(0.9) : Color(red: 0.98, green: 0.62, blue: 0.2).opacity(0.85)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                switch rule {
                case .ruleOfThirds:
                    p.move(to: CGPoint(x: w / 3, y: 0)); p.addLine(to: CGPoint(x: w / 3, y: h))
                    p.move(to: CGPoint(x: 2 * w / 3, y: 0)); p.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 3)); p.addLine(to: CGPoint(x: w, y: h / 3))
                    p.move(to: CGPoint(x: 0, y: 2 * h / 3)); p.addLine(to: CGPoint(x: w, y: 2 * h / 3))
                case .goldenRatio:
                    let a = 1 - 0.618, b = 0.618
                    p.move(to: CGPoint(x: w * a, y: 0)); p.addLine(to: CGPoint(x: w * a, y: h))
                    p.move(to: CGPoint(x: w * b, y: 0)); p.addLine(to: CGPoint(x: w * b, y: h))
                    p.move(to: CGPoint(x: 0, y: h * a)); p.addLine(to: CGPoint(x: w, y: h * a))
                    p.move(to: CGPoint(x: 0, y: h * b)); p.addLine(to: CGPoint(x: w, y: h * b))
                case .centeredCircle:
                    let r = min(w, h) * 0.3
                    p.addEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r, width: 2 * r, height: 2 * r))
                    p.move(to: CGPoint(x: w / 2 - 12, y: h / 2)); p.addLine(to: CGPoint(x: w / 2 + 12, y: h / 2))
                    p.move(to: CGPoint(x: w / 2, y: h / 2 - 12)); p.addLine(to: CGPoint(x: w / 2, y: h / 2 + 12))
                case .diagonal:
                    p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: w, y: h))
                    p.move(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: 0, y: h))
                case .symmetry:
                    p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
                    p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                case .leadingLines:
                    let focal = CGPoint(x: w / 2, y: h * 0.4)
                    for corner in [CGPoint(x: 0, y: h), CGPoint(x: w, y: h), CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)] {
                        p.move(to: corner); p.addLine(to: focal)
                    }
                case .frameWithinFrame:
                    p.addRect(CGRect(x: w * 0.15, y: h * 0.15, width: w * 0.7, height: h * 0.7))
                    p.addRect(CGRect(x: w * 0.28, y: h * 0.28, width: w * 0.44, height: h * 0.44))
                case .foregroundInterest:
                    p.move(to: CGPoint(x: 0, y: h * 0.55)); p.addLine(to: CGPoint(x: w, y: h * 0.55))
                    p.move(to: CGPoint(x: 0, y: h * 0.85)); p.addLine(to: CGPoint(x: w, y: h * 0.85))
                case .layering:
                    p.move(to: CGPoint(x: 0, y: h * 0.33)); p.addLine(to: CGPoint(x: w, y: h * 0.33))
                    p.move(to: CGPoint(x: 0, y: h * 0.66)); p.addLine(to: CGPoint(x: w, y: h * 0.66))
                }
            }
            .stroke(lineColor, style: StrokeStyle(lineWidth: 1.2, dash: rule == .leadingLines ? [6, 4] : []))

            ForEach(Array(rule.targetPoints(in: geo.size).enumerated()), id: \.offset) { _, pt in
                Circle()
                    .stroke(lineColor, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                    .position(pt)
            }
        }
        .allowsHitTesting(false)
    }
}
