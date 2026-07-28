import UIKit

struct CoachTip: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let advice: String
    let icon: String
    /// What Claude actually sees — shown so you can tell instantly if it misread the scene.
    let scene: String?
    /// Zoom Claude thinks the shot wants, on the display scale (1.0 = normal lens).
    /// `nil` when it judged the current framing already right, or didn't answer.
    let suggestedZoom: Double?
}

enum AdviceError: LocalizedError {
    case noAPIKey
    case badResponse(String)
    case parseFailure
    case noFrame

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Add your Anthropic API key in Settings first."
        case .badResponse(let msg): return msg
        case .parseFailure: return "Couldn't read the coach's tip. Try again."
        case .noFrame: return "No camera frame available yet."
        }
    }
}

enum AdviceService {
    /// AI Partner: analyze the current framing and return ONE highest-impact coaching tip.
    static func partnerTip(
        snapshot: UIImage,
        rule: CompositionRule,
        subject: SubjectObservation?,
        userSelectedSubject: Bool,
        currentZoom: Double,
        zoomRange: ClosedRange<Double>
    ) async throws -> CoachTip {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AdviceError.noAPIKey
        }
        guard let jpeg = snapshot.jpegData(compressionQuality: 0.7) else {
            throw AdviceError.parseFailure
        }

        // The on-device detector only knows 80 COCO classes — it has no idea what a
        // bridge, river, ridgeline or building is. So its output is offered as a WEAK
        // hint that Claude is explicitly told to override. Claude does the seeing.
        var hintLine = "The on-device detector found nothing it recognises. That is expected for landscapes, architecture and water — identify the scene yourself."
        if let s = subject {
            let h = s.center.x < 0.4 ? "left" : (s.center.x > 0.6 ? "right" : "center")
            let v = s.center.y < 0.4 ? "top" : (s.center.y > 0.6 ? "bottom" : "middle")
            let size = Int(s.box.width * s.box.height * 100)
            let what = s.label.map { " and guessed it might be a \($0)" } ?? ""
            if userSelectedSubject {
                hintLine = "The user TAPPED a region at the \(v)-\(h) of the frame (about \(size)% of the image)\(what). Treat that location as what they care about, but trust your own eyes about WHAT it actually is — the label is often wrong."
            } else {
                hintLine = "A weak automatic guess put something at the \(v)-\(h) of the frame, about \(size)% of the image\(what). This guess is frequently wrong — override it if you see a better subject."
            }
        }

        func zoomText(_ value: Double) -> String {
            value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%.1f×", value)
        }

        let prompt = """
You are a professional photographer standing at the user's shoulder as they line up a shot on an iPhone. You can see exactly what their camera sees. Assume the user is a beginner who does not know what makes a photo good — your job is to hand them one decision, already made.

\(hintLine)

The on-screen composition guide is currently set to: \(rule.rawValue). If that guide is wrong for this scene, say so in your advice.

ZOOM: this frame was captured at \(zoomText(currentZoom)) on the phone's zoom scale, where 1× is the normal lens. The phone can go from \(zoomText(zoomRange.lowerBound)) to \(zoomText(zoomRange.upperBound)). Coach mode deliberately pulls the camera back to the widest lens so you can see the whole scene, so the frame you are given is usually WIDER than the photo the user should actually take.

Work in three steps.

STEP 1 — Look at the image and identify what is actually in front of you. Name the real scene concretely: what the subject is, the setting, the light, and the notable structures or natural features (for example "stone bridge over a river, overcast, trees both banks" or "woman on a bench, backlit by low sun"). Be specific about things an object detector would miss: water, bridges, buildings, mountains, roads, horizons, reflections, leading lines.

STEP 2 — Given that scene, give the SINGLE highest-impact change to improve this shot right now. Consider viewpoint, height, distance, where the natural lines lead, horizon placement, light direction, exposure, clutter and timing — then pick only the ONE thing that matters most.

STEP 3 — Decide how tight the shot should be. Beginners overwhelmingly shoot too wide, leaving the subject small and the frame full of nothing. Pick the zoom that fills the frame properly with what matters, between \(zoomText(zoomRange.lowerBound)) and \(zoomText(zoomRange.upperBound)). Prefer a real lens stop (\(zoomText(zoomRange.lowerBound)), 1×, 2×) over an arbitrary number, since those are optically sharper. Choose the wide end only when the scene genuinely needs the space — a sweeping landscape, a tight interior, a foreground you want exaggerated.

Rules for the advice:
- Concrete and physical: what to DO ("crouch to water level", "step left so the bridge cuts the corner", "wait for the sun off the railing")
- It must clearly refer to something you actually see in THIS frame, not generic advice
- Max 16 words
- No jargon, no gear suggestions, no explanation of why
- Do not mention zoom in the advice text — the zoom is returned separately and the app offers it as its own button

Respond with ONLY this JSON, no code fences, no preamble:
{"scene": "<6-10 words naming what you actually see>", "title": "<one word category e.g. Angle, Light, Distance, Framing, Clutter, Timing, Horizon>", "advice": "<the instruction>", "icon": "<one SF Symbol name that fits, e.g. arrow.down.circle, sun.max, arrow.left.and.right, viewfinder, trash, clock, water.waves, mountain.2>", "zoom": <number, the zoom this shot should be taken at>}
"""

        let body: [String: Any] = [
            "model": CritiqueService.model,
            "max_tokens": 300,
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
        request.timeoutInterval = 25

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

        struct TipData: Decodable {
            let title: String
            let advice: String
            let icon: String
            let scene: String?
            let zoom: Double?
        }
        guard let d = cleaned.data(using: .utf8),
              let tip = try? JSONDecoder().decode(TipData.self, from: d) else {
            throw AdviceError.parseFailure
        }
        // Clamp rather than trust: a hallucinated "12×" on a phone that stops at 5
        // would otherwise show the user a button that does nothing recognisable.
        let zoom = tip.zoom.map { min(max($0, zoomRange.lowerBound), zoomRange.upperBound) }
        return CoachTip(title: tip.title, advice: tip.advice, icon: tip.icon,
                        scene: tip.scene, suggestedZoom: zoom)
    }
}
