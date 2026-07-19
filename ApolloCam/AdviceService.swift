import UIKit
import CoreVideo
import Vision

struct AdviceCard: Identifiable {
    let id = UUID()
    let title: String
    let advice: String
    let icon: String
}

enum AdviceError: LocalizedError {
    case noAPIKey
    case badResponse(String)
    case parseFailure
    case frameConversionFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Add your Anthropic API key in Settings first."
        case .badResponse(let msg): return msg
        case .parseFailure: return "Couldn't parse the advice. Try again."
        case .frameConversionFailed: return "Couldn't process the camera frame."
        }
    }
}

enum AdviceService {
    /// Convert CVPixelBuffer (camera frame) to JPEG base64 for Claude Vision API
    private static func frameToBase64(_ buffer: CVPixelBuffer) throws -> String {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw AdviceError.frameConversionFailed
        }
        let uiImage = UIImage(cgImage: cgImage).resized(maxDimension: 720)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.7) else {
            throw AdviceError.frameConversionFailed
        }
        return jpeg.base64EncodedString()
    }

    /// Get live coaching advice from Claude Vision based on current frame + composition rule
    static func getAdvice(
        frameBuffer: CVPixelBuffer,
        rule: CompositionRule,
        subject: SubjectObservation?
    ) async throws -> [AdviceCard] {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AdviceError.noAPIKey
        }

        let base64Image = try frameToBase64(frameBuffer)

        let prompt = """
You are a professional photography coach analyzing a live camera frame.

Current composition rule: \(rule.rawValue)
Subject detected: \(subject.map { "centered at (\(String(format: "%.1f", $0.center.x)), \(String(format: "%.1f", $0.center.y)))" } ?? "none")

Analyze this frame and respond with ONLY a JSON object (no markdown, no preamble).

Focus on 3–4 highest-impact improvements in these priority areas:
1. Composition & framing (subject placement, rule of thirds, leading lines, layers)
2. Angle & perspective (camera angle, depth, foreground/background)
3. Lighting & exposure (light direction, shadows, highlights, contrast)
4. Distance & zoom (how close/far, what to include/exclude)

For each recommendation, provide:
- title: the element (e.g. "Angle", "Lighting", "Distance")
- advice: one concrete actionable step in 12 words or less (e.g. "Lower your angle to emphasize the horizon")
- icon: a single SF Symbol name (e.g. "square.and.arrow.up", "flashlight.on.fill", "arrow.left.and.right")

Respond ONLY with this JSON structure (no code fences):
{"cards": [{"title": "...", "advice": "...", "icon": "..."}, ...]}
"""

        let body: [String: Any] = [
            "model": CritiqueService.model,
            "max_tokens": 600,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64Image]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String } ?? "API error \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw AdviceError.badResponse(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first else {
            throw AdviceError.parseFailure
        }

        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        struct CardData: Decodable {
            let title: String
            let advice: String
            let icon: String
        }
        struct Response: Decodable {
            let cards: [CardData]
        }

        guard let data = cleaned.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AdviceError.parseFailure
        }

        return response.cards.map { AdviceCard(title: $0.title, advice: $0.advice, icon: $0.icon) }
    }
}
