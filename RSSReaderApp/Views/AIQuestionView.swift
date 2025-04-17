import SwiftUI

struct AIQuestionView: View {
    @State private var questionText: String = ""

    var body: some View {
        TextField("Ask a question about this article...", text: $questionText)
            .onSubmit {
                if !questionText.isEmpty {
                    askQuestion()
                }
            }
            .submitLabel(.send)
    }

    private func askQuestion() {
        // Implementation of askQuestion function
    }
}

struct AIQuestionView_Previews: PreviewProvider {
    static var previews: some View {
        AIQuestionView()
    }
} 