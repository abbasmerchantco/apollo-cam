import UIKit

/// Claude cannot return an edited image — it is not an image generator. So it returns
/// correction *values* in our normalized ranges, and `ImagePipeline` applies them on
/// device. The user can then fine-tune every slider afterwards: nothing is a black box.
enum AdjustService {

    struct Result {
        let adjustments: EditAdjustments
        let note: String
    }

    static func suggestAdjustments(for image: UIImage) async throws -> Result {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AdviceError.noAPIKey
        }
        // Send a modest proxy — colour analysis doesn't need full resolution.
        let small = ImagePipeline.preview(from: image, maxSide: 900)
        guard let jpeg = small.jpegData(compressionQuality: 0.7) else {
            throw AdviceError.parseFailure
        }

        let prompt = """
You are a photo editor performing colour correction on this photograph.

First read the image honestly: its white balance, exposure, contrast, and whether highlights are blown or shadows are blocked. Then choose correction values.

Every value below is NEUTRAL AT 0. Only move a value if the image genuinely needs it — a well-exposed photo should come back with most values at or near 0. Do not "improve" a photo that is already correct, and never apply a heavy stylistic look.

Value ranges (stay inside them):
- exposure: -2 to 2 (stops; use for genuine under/over exposure)
- brightness: -1 to 1 (gentle overall lift)
- contrast: -1 to 1
- saturation: -1 to 1 (positive adds colour; keep skin tones natural)
- warmth: -1 to 1 (negative cools a warm/orange cast, positive warms a blue cast)
- tint: -1 to 1 (negative toward green, positive toward magenta)
- highlights: -1 to 1 (negative recovers blown highlights)
- shadows: -1 to 1 (positive lifts crushed shadows)
- sharpness: 0 to 1 (use sparingly, 0 unless visibly soft)
- vignette: 0 to 1 (usually 0)

Typical corrections are small: values between -0.4 and 0.4. Reserve anything larger for clearly broken exposure or a strong colour cast.

Respond with ONLY this JSON, no code fences, no preamble:
{"exposure": 0, "brightness": 0, "contrast": 0, "saturation": 0, "warmth": 0, "tint": 0, "highlights": 0, "shadows": 0, "sharpness": 0, "vignette": 0, "note": "<max 18 words naming what you corrected and why>"}
"""

        let body: [String: Any] = [
            "model": CritiqueService.model,
            "max_tokens": 500,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
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
                .flatMap { $0["message"] as? String } ?? "API error \(http.statusCode)"
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

        struct Payload: Decodable {
            let exposure: Double?
            let brightness: Double?
            let contrast: Double?
            let saturation: Double?
            let warmth: Double?
            let tint: Double?
            let highlights: Double?
            let shadows: Double?
            let sharpness: Double?
            let vignette: Double?
            let note: String?
        }

        guard let d = cleaned.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: d) else {
            throw AdviceError.parseFailure
        }

        // Clamp defensively — never trust a model to stay inside the stated range.
        func c(_ v: Double?, _ lo: Double, _ hi: Double) -> Double {
            min(max(v ?? 0, lo), hi)
        }

        var a = EditAdjustments()
        a.exposure   = c(p.exposure,   -2, 2)
        a.brightness = c(p.brightness, -1, 1)
        a.contrast   = c(p.contrast,   -1, 1)
        a.saturation = c(p.saturation, -1, 1)
        a.warmth     = c(p.warmth,     -1, 1)
        a.tint       = c(p.tint,       -1, 1)
        a.highlights = c(p.highlights, -1, 1)
        a.shadows    = c(p.shadows,    -1, 1)
        a.sharpness  = c(p.sharpness,   0, 1)
        a.vignette   = c(p.vignette,    0, 1)

        let note = (p.note?.isEmpty == false ? p.note! : "Applied a light correction.")
        return Result(adjustments: a, note: note)
    }
}
