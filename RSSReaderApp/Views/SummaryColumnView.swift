import SwiftUI

struct SummaryColumnView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading) {
            if let article = appState.selectedArticle {
                Text("Summary for:")
                    .font(.headline)
                    .padding(.bottom, 2)
                Text(article.title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.bottom, 8)
                
                if appState.isLoading {
                    ProgressView("Generating summary...")
                        .padding()
                } else if let summary = article.summary, !summary.isEmpty {
                    ScrollView {
                        Text(summary)
                            .padding()
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Button(action: {
                        appState.summarizeArticle(article)
                    }) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Summarize Article")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .padding(.top, 16)
                }
            } else {
                Text("Select an article to see its summary.")
                    .foregroundColor(.secondary)
                    .padding()
            }
            Spacer()
        }
        .frame(minWidth: 300)
        .padding()
    }
}

struct SummaryColumnView_Previews: PreviewProvider {
    static var previews: some View {
        SummaryColumnView()
            .environmentObject(AppState())
            .previewLayout(.sizeThatFits)
    }
}
