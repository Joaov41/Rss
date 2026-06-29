import SwiftUI

struct AddSubscriptionView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var title: String = ""
    @State private var url: String = ""
    @State private var type: SubscriptionType = .rss
    @State private var errorMessage: String?
    
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack {
                    Text("Add Subscription")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                Divider()
            }
            
            // Content
            Form {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                
                Picker("Type", selection: $type) {
                    Text("RSS Feed").tag(SubscriptionType.rss)
                    Text("Reddit").tag(SubscriptionType.reddit)
                }
                .pickerStyle(.segmented)
                
                TextField(
                    type == .rss ? "Feed URL" : "Subreddit Name",
                    text: $url,
                    prompt: Text(type == .rss ? "https://example.com/feed" : "technology")
                )
                .textFieldStyle(.roundedBorder)
                
                if type == .reddit {
                    Text("Enter subreddit name without 'r/' prefix")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let errorMessage = errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .padding()
            
            // Footer
            VStack(spacing: 0) {
                Divider()
                
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Add") {
                        addSubscription()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty || url.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 450, height: 340)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        NavigationView {
            Form {
                Section(header: Text("Subscription Details")) {
                    TextField("Title", text: $title)
                    
                    Picker("Type", selection: $type) {
                        Text("RSS Feed").tag(SubscriptionType.rss)
                        Text("Reddit").tag(SubscriptionType.reddit)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    TextField(type == .rss ? "Feed URL" : "Subreddit Name", text: $url)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    if type == .reddit {
                        Text("Enter subreddit name without 'r/' prefix")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Button("Add Subscription") {
                        addSubscription()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(title.isEmpty || url.isEmpty)
                }
            }
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        #endif
    }
    
    private func addSubscription() {
        errorMessage = nil
        
        if type == .rss && !url.lowercased().starts(with: "http") {
            errorMessage = "Please enter a valid URL starting with http:// or https://"
            return
        }
        
        let finalUrl = type == .rss ? url : url.replacingOccurrences(of: "r/", with: "")
        appState.addSubscription(title: title, url: finalUrl, type: type)
        dismiss()
    }
}