import CoreML
import Vision

/// Loads the user-provided Core ML models from the app bundle.
/// Both are OPTIONAL: the app runs on Vision-framework fallbacks until the
/// compiled models are dropped into ApolloCam/Models/ and rebuilt.
final class MLModels {
    static let shared = MLModels()

    /// YOLOv8n object detector (expects Ultralytics export with NMS, so Vision
    /// returns VNRecognizedObjectObservation directly).
    let yolo: VNCoreMLModel?
    /// Composition classifier: image in → one of the composition class labels out.
    let composition: VNCoreMLModel?

    var yoloAvailable: Bool { yolo != nil }
    var compositionAvailable: Bool { composition != nil }

    private init() {
        yolo = Self.load("YOLOv8n")
        composition = Self.load("CompositionModel")
    }

    private static func load(_ name: String) -> VNCoreMLModel? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine on the 13 Pro Max
        guard let model = try? MLModel(contentsOf: url, configuration: config) else {
            return nil
        }
        return try? VNCoreMLModel(for: model)
    }

    /// Map a classifier label (whatever naming convention the model uses) to our rule enum.
    static func rule(fromLabel label: String) -> CompositionRule? {
        let n = label.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if n.contains("third") { return .ruleOfThirds }
        if n.contains("goldenratio") || n.contains("phi") { return .goldenRatio }
        if n.contains("spiral") { return .goldenRatio }
        if n.contains("radial") { return .radial }
        if n.contains("center") || n.contains("circle") { return .centeredCircle }
        if n.contains("diagonal") { return .diagonal }
        if n.contains("triangle") { return .triangle }
        if n.contains("leading") || n.contains("line") { return .leadingLines }
        if n.contains("symmetr") { return .symmetry }
        if n.contains("frame") { return .frameWithinFrame }
        if n.contains("pattern") || n.contains("repetition") { return .pattern }
        if n.contains("layer") { return .layering }
        if n.contains("foreground") { return .foregroundInterest }
        if n.contains("vanish") { return .vanishingPoint }
        if n.contains("curve") { return .sCurve }
        return nil
    }
}
