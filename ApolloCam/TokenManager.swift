import Foundation
import Combine

final class TokenManager: ObservableObject {
    static let shared = TokenManager()

    @Published private(set) var dailyAdviceTokens: Int = 0
    @Published private(set) var dailyEvalTokens: Int = 0

    private let adviceKey = "apollocam.advice.tokens"
    private let evalKey = "apollocam.eval.tokens"
    private let dateKey = "apollocam.tokens.date"

    private let maxDailyAdvice = 20  // Free tier: 20 advice taps/day (cost-effective)
    private let maxDailyEval = 10    // Free tier: 10 photo evals/day

    init() {
        resetIfNewDay()
    }

    private func resetIfNewDay() {
        let today = Calendar.current.startOfDay(for: Date())
        let lastDate = UserDefaults.standard.object(forKey: dateKey) as? Date ?? .distantPast
        let lastDay = Calendar.current.startOfDay(for: lastDate)

        if today > lastDay {
            // New day — reset tokens
            UserDefaults.standard.set(today, forKey: dateKey)
            UserDefaults.standard.set(maxDailyAdvice, forKey: adviceKey)
            UserDefaults.standard.set(maxDailyEval, forKey: evalKey)
            DispatchQueue.main.async {
                self.dailyAdviceTokens = self.maxDailyAdvice
                self.dailyEvalTokens = self.maxDailyEval
            }
        } else {
            // Same day — restore from UserDefaults
            dailyAdviceTokens = UserDefaults.standard.integer(forKey: adviceKey)
            dailyEvalTokens = UserDefaults.standard.integer(forKey: evalKey)
            if dailyAdviceTokens == 0 {
                dailyAdviceTokens = maxDailyAdvice
                UserDefaults.standard.set(dailyAdviceTokens, forKey: adviceKey)
            }
            if dailyEvalTokens == 0 {
                dailyEvalTokens = maxDailyEval
                UserDefaults.standard.set(dailyEvalTokens, forKey: evalKey)
            }
        }
    }

    var canUseAdvice: Bool { dailyAdviceTokens > 0 }
    var canUseEval: Bool { dailyEvalTokens > 0 }

    func useAdviceToken() {
        guard dailyAdviceTokens > 0 else { return }
        dailyAdviceTokens -= 1
        UserDefaults.standard.set(dailyAdviceTokens, forKey: adviceKey)
    }

    func useEvalToken() {
        guard dailyEvalTokens > 0 else { return }
        dailyEvalTokens -= 1
        UserDefaults.standard.set(dailyEvalTokens, forKey: evalKey)
    }

    /// For pro/paid users: grant unlimited tokens
    func setPro(_ enabled: Bool) {
        if enabled {
            dailyAdviceTokens = Int.max
            dailyEvalTokens = Int.max
        } else {
            resetIfNewDay()
        }
    }
}
