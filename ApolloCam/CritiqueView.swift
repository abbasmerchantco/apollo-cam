import SwiftUI

struct CritiqueView: View {
    let image: UIImage
    var entryID: UUID? = nil
    var mode: CritiqueMode = .myPhoto

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tokenManager = TokenManager.shared
    @State private var critique: Critique?
    @State private var loading = false
    @State private var errorMessage: String?

    private let gold = Color(red: 0.98, green: 0.75, blue: 0.24)

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)

                    if loading {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Your coach is looking at the photo…")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 30)
                    } else if let critique {
                        critiqueContent(critique)
                    } else if let errorMessage {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(errorMessage)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                            Button("Try again") { Task { await run() } }
                                .buttonStyle(.borderedProminent)
                                .tint(gold)
                        }
                        .padding()
                    } else if !tokenManager.canUseEval {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text("No evaluation tokens left today")
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                            Text("You have 10 free evals per day. Upgrade to Pro for unlimited.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    } else {
                        Button {
                            Task { await run() }
                        } label: {
                            Label(mode == .myPhoto ? "Evaluate this photo" : "Break down this photo",
                                  systemImage: "sparkles")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(gold)
                        .foregroundColor(.black)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(mode == .myPhoto ? "Evaluate" : "Learn from this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // If this entry already has a saved critique, show it
            if let entryID, let saved = PhotoStore.shared.entries.first(where: { $0.id == entryID })?.critique {
                critique = saved
            }
        }
    }

    @ViewBuilder
    private func critiqueContent(_ c: Critique) -> some View {
        VStack(spacing: 14) {
            // Overall
            VStack(spacing: 6) {
                Text("\(c.overall)/10")
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .foregroundColor(gold)
                Text(c.summary)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal)

            ForEach(c.dimensions) { dim in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(dim.name).font(.headline)
                        Spacer()
                        Text("\(dim.score)/10")
                            .font(.subheadline.weight(.bold).monospaced())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(gold.opacity(0.18), in: Capsule())
                            .foregroundColor(gold)
                    }
                    Text(dim.feedback)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.85))
                    Label(dim.tip, systemImage: "lightbulb.fill")
                        .font(.footnote)
                        .foregroundColor(gold.opacity(0.95))
                }
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            }
        }
    }

    private func run() async {
        loading = true
        errorMessage = nil
        do {
            let result = try await CritiqueService.critique(image: image, mode: mode)
            critique = result
            tokenManager.useEvalToken()
            if let entryID { PhotoStore.shared.attachCritique(result, to: entryID) }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}
