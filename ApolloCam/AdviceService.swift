import UIKit

struct CoachTip: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let advice: String
    let icon: String
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
        userSelectedSubject: Bool
    ) async throws -> CoachTip {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw AdviceError.noAPIKey
        }
        guard let jpeg = snapshot.jpegData(compressionQuality: 0.7) else {
            throw AdviceError.parseFailure
        }

        var subjectLine = "No subject has been identified yet."
        if let s = subject {
            let h = s.center.x < 0.4 ? "left" : (s.center.x > 0.6 ? "right" : "center")
            let v = s.center.y < 0.4 ? "top" : (s.center.y > 0.6 ? "bottom" : "middle")
            let size = Int(s.box.width * s.box.height * 100)
            let what = s.label.map { " (detected as: \($0))" } ?? ""
            if userSelectedSubject {
                subjectLine = "IMPORTANT: The user has explicitly tapped their intended subject\(what). It sits at the \(v)-\(h) of the frame and fills roughly \(size)% of it. All advice must serve THIS subject."
            } else {
                subjectLine = "Auto-detected likely subject\(what) at the \(v)-\(h) of the frame, filling roughly \(size)% of it."
            }
        }

        let prompt = """
You are a professional photographer coaching over the user's shoulder as they line up a shot on an iPhone.

\(subjectLine)
The on-screen composition guide is currently: \(rule.rawValue).

Look at the frame and give the SINGLE highest-impact instruction to improve this shot right now. Consider composition, camera angle, distance, lighting direction, exposure, distracting elements, and timing — but pick only the ONE change that matters most.

Rules for the advice:
- Concrete and physical: what to DO ("crouch lower", "step two paces left", "put the sun behind her")
- Max 14 words
- No jargon, no explanations, no gear suggestions

Respond with ONLY this JSON, no code fences, no preamble:
{"title": "<one word category e.g. Angle, Light, Distance, Framing, Clutter, Timing>", "advice": "<the instruction>", "icon": "<one SF Symbol name that fits, e.g. arrow.down.circle, sun.max, arrow.left.and.right, viewfinder, trash, clock>"}
"""

        let body: [String: Any] = [
            "model": CritiqueService.model,
            "max_tokens": 200,
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

        struct TipData: Decodable { let title: String; let advice: String; let icon: String }
        guard let d = cleaned.data(using: .utf8),
              let tip = try? JSONDecoder().decode(TipData.self, from: d) else {
            throw AdviceError.parseFailure
        }
        return CoachTip(title: tip.title, advice: tip.advice, icon: tip.icon)
    }
}
