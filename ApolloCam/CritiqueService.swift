import UIKit
import Security

// MARK: - Keychain (API key storage)

enum Keychain {
    private static let service = "co.abbasmerchant.apollocam"
    private static let account = "anthropic-api-key"

    static func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Critique service

enum CritiqueError: LocalizedError {
    case noAPIKey
    case badResponse(String)
    case parseFailure

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "Add your Anthropic API key in Settings first."
        case .badResponse(let msg): return msg
        case .parseFailure: return "Couldn't parse the critique. Try again."
        }
    }
}

enum CritiqueService {
    /// Model choice: Haiku is fast and cheap (a critique costs well under a cent).
    /// Change to "claude-sonnet-4-6" in Settings for richer feedback.
    static var model: String {
        UserDefaults.standard.string(forKey: "critiqueModel") ?? "claude-haiku-4-5-20251001"
    }

    static func critique(image: UIImage, mode: CritiqueMode) async throws -> Critique {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            throw CritiqueError.noAPIKey
        }

        // Downscale to keep tokens + upload small; 1024px longest edge is plenty for critique.
        let resized = image.resized(maxDimension: 1024)
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else {
            throw CritiqueError.parseFailure
        }
        let base64 = jpeg.base64EncodedString()

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1200,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]],
                    ["type": "text", "text": mode.prompt]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String } ?? "API error \( (response as? HTTPURLResponse)?.statusCode ?? 0)"
            throw CritiqueError.badResponse(msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.compactMap({ $0["text"] as? String }).first else {
            throw CritiqueError.parseFailure
        }

        // Strip markdown fences if the model added them
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let critiqueData = cleaned.data(using: .utf8),
              let critique = try? JSONDecoder().decode(Critique.self, from: critiqueData) else {
            throw CritiqueError.parseFailure
        }
        return critique
    }
}

enum CritiqueMode {
    case myPhoto        // critique of the user's own shot
    case learnFromPro   // breakdown of why a found/pro photo works

    var prompt: String {
        let schema = """
        Respond with ONLY valid JSON, no markdown, matching exactly this schema:
        {"overall": <int 0-10>, "summary": "<one sentence, the single biggest takeaway>", "dimensions": [{"name": "Composition", "score": <int 0-10>, "feedback": "<2-3 sentences of specific observation>", "tip": "<one concrete, actionable thing to do next time, plain language, no jargon>"}, ... same for "Lighting", "Color", "Focus", "Aesthetics"]}
        """
        switch self {
        case .myPhoto:
            return """
            You are a friendly professional photography coach reviewing a beginner's photo. \
            Be specific about what's in THIS image (name actual elements you see), honest but encouraging. \
            Tips must be actionable with a phone camera — position, angle, timing, exposure, framing — never gear purchases. \
            \(schema)
            """
        case .learnFromPro:
            return """
            You are a photography teacher breaking down why this photo works (or doesn't). \
            The student didn't take this photo — they want to learn from it. \
            For each dimension explain the technique used and how a beginner could replicate it with a phone. \
            \(schema)
            """
        }
    }
}

extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
