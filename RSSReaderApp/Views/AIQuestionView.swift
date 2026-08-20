import SwiftUI

struct AIQuestionView: View {
    /// Optional article/post text to use as context for the question.
    var articleContent: String = ""

    @EnvironmentObject var appState: AppState

    @State private var questionText: String = ""
    @State private var isLoading: Bool = false
    @State private var answer: String = ""
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark ? [
                    Color.indigo.opacity(0.3),
                    Color.purple.opacity(0.4),
                    Color.pink.opacity(0.3),
                    Color.orange.opacity(0.2),
                    Color.yellow.opacity(0.2)
                ] : [
                    Color.indigo.opacity(0.8),
                    Color.purple.opacity(0.9),
                    Color.pink.opacity(0.7),
                    Color.orange.opacity(0.6),
                    Color.yellow.opacity(0.5)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Text("Ask AI About This Article")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                VStack(spacing: 16) {
                    if #available(iOS 26.0, *) {
                        TextField("Ask a question about this article...", text: $questionText)
                            .textFieldStyle(LiquidGlassTextFieldStyle())
                            .onSubmit { submitQuestion() }
                    } else {
                        TextField("Ask a question about this article...", text: $questionText)
                            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(cornerRadius: 12, tintColor: .blue.opacity(0.3)))
                            .onSubmit { submitQuestion() }
                    }

                    HStack {
                        Button {
                            submitQuestion()
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .accessibilityLabel("Ask")
                        .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .blue.opacity(0.4)))
                        .disabled(questionText.isEmpty || isLoading)

                        Button {
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .accessibilityLabel("Cancel")
                        .buttonStyle(AdaptiveLiquidGlassButtonStyle(tintColor: .red.opacity(0.3)))
                    }
                }

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                        .padding()
                }

                if !answer.isEmpty {
                    ScrollView {
                        Text(answer)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                    )
                            )
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)

                    // Throughput badge for on-device providers only
                    let throughput = appState.mlxLastThroughput
                    if !throughput.isEmpty,
	                       (appState.settings.selectedSummaryProvider == .appleLocal ||
	                        appState.settings.selectedSummaryProvider == .mlxLocal ||
	                        appState.settings.selectedSummaryProvider == .coreAIMLXLocal ||
	                        appState.settings.selectedSummaryProvider == .applePCCGateway ||
	                        appState.settings.selectedSummaryProvider == .summarizeDaemon) {
                        HStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.caption2)
                            Text(throughput)
                                .font(.caption2)
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    private func submitQuestion() {
        guard !questionText.isEmpty else { return }
        isLoading = true
        answer = ""

        appState.answerQuestion(questionText, context: articleContent) { @MainActor result in
            self.answer = result
            self.isLoading = false
        }
    }
}

struct AIQuestionView_Previews: PreviewProvider {
    static var previews: some View {
        AIQuestionView()
            .environmentObject(AppState())
    }
}
