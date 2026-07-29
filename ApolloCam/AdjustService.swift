import UIKit

/// Claude cannot return an edited image — it is not an image generator. So it returns
/// correction *values* in our normalized ranges, and `ImagePipeline` applies them on
/// device. The user can then fine-tune every slider afterwards: nothing is a black box.
enum AdjustService {

    struct Result {
        let adjustments: EditAdjustments
        let note: String
        /// Suggested crop, or nil when the framing is already good. Normalized
        /// (0...1) with a top-left origin, expressed against the image *as sent* —
        /// i.e. before the user's `rotationQuarters`/`flipH` are applied. Callers
        /// must map it into the oriented frame via `ImagePipeline.orientedCropRect`
        /// before assigning it to `EditAdjustments.cropRect`. Keeping it in the
        /// un-oriented frame is what lets the cached suggestion stay valid when the
        /// user rotates the photo after the analysis was made.
        let suggestedCrop: CGRect?
        let cropNote: String?
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

HORIZON

Also check the image for a tilted horizon or a vertical reference that should be upright — a sea/land horizon line, a building edge, a doorframe, a horizon implied by the ground plane. If one is visibly off-level, return a "straighten" value in DEGREES to rotate the image so it reads level: positive rotates clockwise, negative rotates counter-clockwise. Most photos are already level — return 0 unless you can actually see the tilt. Typical corrections are small, -10 to 10 degrees; only go higher for an obviously crooked shot. Never invent a horizon that isn't visibly there just to justify a non-zero value.

CROP

Then judge the framing. Propose a crop ONLY if one would clearly improve the photograph — dead space around the subject, a subject stranded off-balance, a distracting element at an edge. If the framing is already working, return null. Most photographs should get null; the same restraint that applies to the colour values applies here.

The crop is given in fractions of the image with (0,0) at the TOP-LEFT corner:
- x, y: top-left corner of the crop
- width, height: size of the crop
All four are 0 to 1, and x+width and y+height must not exceed 1.

Never go below 0.4 for width or height — this is a photograph being re-framed, not a detail being extracted. Never cut through a face or through the main subject.

Respond with ONLY this JSON, no code fences, no preamble:
{"exposure": 0, "brightness": 0, "contrast": 0, "saturation": 0, "warmth": 0, "tint": 0, "highlights": 0, "shadows": 0, "sharpness": 0, "vignette": 0, "straighten": 0, "note": "<max 18 words naming what you corrected and why>", "crop": null, "cropNote": "<max 14 words on why this crop, or empty if crop is null>"}
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

        struct CropPayload: Decodable {
            let x: Double?
            let y: Double?
            let width: Double?
            let height: Double?
        }

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
            let straighten: Double?
            let note: String?
            let crop: CropPayload?
            let cropNote: String?
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
        a.straighten = c(p.straighten, -45, 45)

        // Crop is optional and rejected outright unless it is well-formed, inside
        // the frame, and actually a crop. A malformed rect here would silently
        // throw away most of the photograph, so the bar is deliberately high.
        var suggestedCrop: CGRect?
        if let cp = p.crop,
           let x = cp.x, let y = cp.y, let w = cp.width, let h = cp.height,
           x.isFinite, y.isFinite, w.isFinite, h.isFinite {
            let r = CGRect(x: x, y: y, width: w, height: h)
            let insideFrame = r.minX >= -0.001 && r.minY >= -0.001
                && r.maxX <= 1.001 && r.maxY <= 1.001
            let bigEnough = r.width >= 0.4 && r.height >= 0.4
            let isFullFrame = r.width > 0.99 && r.height > 0.99
            if insideFrame, bigEnough, !isFullFrame {
                suggestedCrop = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }

        let note = (p.note?.isEmpty == false ? p.note! : "Applied a light correction.")
        let cropNote = suggestedCrop == nil ? nil
            : (p.cropNote?.isEmpty == false ? p.cropNote! : "Tightened the framing.")
        return Result(adjustments: a, note: note,
                      suggestedCrop: suggestedCrop, cropNote: cropNote)
    }
}
