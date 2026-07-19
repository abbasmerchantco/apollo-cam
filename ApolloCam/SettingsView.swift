import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var keySaved = Keychain.loadAPIKey() != nil
    @ObservedObject private var tokenManager = TokenManager.shared
    @AppStorage("critiqueModel") private var model = "claude-haiku-4-5-20251001"

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)

    var body: some View {
        NavigationView {
            Form {
                Section {
                    LabeledContent("Live advice", value: "\(tokenManager.dailyAdviceTokens) left today")
                    LabeledContent("Photo evals", value: "\(tokenManager.dailyEvalTokens) left today")
                } header: {
                    Text("Today's tokens")
                } footer: {
                    Text("Free tier includes 20 live advice taps and 10 photo evaluations per day. Resets at midnight.")
                }

                Section {
                    if keySaved {
                        HStack {
                            Label("API key saved", systemImage: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                Keychain.deleteAPIKey()
                                keySaved = false
                                apiKey = ""
                            }
                        }
                    } else {
                        SecureField("sk-ant-…", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save key") {
                            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            Keychain.saveAPIKey(trimmed)
                            keySaved = true
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Powers the photo critique coach. Create a key at console.anthropic.com → API keys. Stored securely in the iOS Keychain, only ever sent to api.anthropic.com.")
                }

                Section {
                    Picker("Coach model", selection: $model) {
                        Text("Haiku — fast and cheap").tag("claude-haiku-4-5-20251001")
                        Text("Sonnet — richer feedback").tag("claude-sonnet-4-6")
                    }
                } header: {
                    Text("Critique quality")
                } footer: {
                    Text("Haiku costs a fraction of a cent per critique. Sonnet gives deeper feedback for a few cents per photo.")
                }

                Section {
                    LabeledContent("Version", value: "0.1 (MVP)")
                    LabeledContent("Composition detection", value: "On-device")
                    LabeledContent("Photo critique", value: "Claude API")
                } header: {
                    Text("About Apollo Cam")
                } footer: {
                    Text("Composition guidance and subject detection run entirely on your iPhone — those frames never leave the device. Photos are only uploaded when you tap Evaluate.")
                }
            }
            .navigationTitle("Settings")
        }
        .preferredColorScheme(.dark)
    }
}
