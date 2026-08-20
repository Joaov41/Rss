import SwiftUI

struct AIQuestionView: View {
    @State private var questionText: String = ""
    @State private var isLoading: Bool = false
    @State private var answer: String = ""
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            // Adaptive gradient background
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
                            .onSubmit {
                                if !questionText.isEmpty {
                                    askQuestion()
                                }
                            }
                    } else {
                        TextField("Ask a question about this article...", text: $questionText)
                            .textFieldStyle(AdaptiveLiquidGlassTextFieldStyle(cornerRadius: 12, tintColor: .blue.opacity(0.3)))
                            .onSubmit {
                                if !questionText.isEmpty {
                                    askQuestion()
                                }
                            }
                    }
                    
                    HStack {
                        Button {
                            askQuestion()
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
                        Text(.init(answer))
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
                    }
                    .frame(maxHeight: 300)
                }
                
                Spacer()
            }
            .padding()
        }
    }

    private func askQuestion() {
        guard !questionText.isEmpty else { return }
        
        isLoading = true
        answer = ""
        
        // Simulate API call - replace with actual implementation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.isLoading = false
            self.answer = "This is a sample answer to demonstrate the glass effect UI. The actual implementation would connect to your AI service."
        }
    }
}

struct AIQuestionView_Previews: PreviewProvider {
    static var previews: some View {
        AIQuestionView()
    }
} 
