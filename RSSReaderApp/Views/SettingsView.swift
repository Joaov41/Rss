import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var showingFileImporter = false
    @State private var importResult: String?
    @State private var showingImportResult = false
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("GEMINI API KEY")) {
                    TextField("Enter your Gemini API Key", text: $appState.settings.geminiApiKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                Section(header: Text("IMPORT/EXPORT")) {
                    Button(action: {
                        showingFileImporter = true
                    }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Subscriptions from OPML")
                        }
                    }
                    .disabled(isImporting) // Disable while importing is in progress
                }
                
                if isImporting {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding()
                            Spacer()
                        }
                    }
                }
                
                Section {
                    HStack {
                        Spacer()
                        // SAVE button
                        Button("Save") {
                            appState.updateSettings(appState.settings)
                        }
                        Spacer()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                // CLOSE button for dismissing the sheet
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [UTType.xml, UTType.plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let files):
                    if let file = files.first {
                        // Start import process
                        isImporting = true
                        appState.importOPMLFromURL(file) { result in
                            isImporting = false
                            switch result {
                            case .success(let count):
                                if count > 0 {
                                    importResult = "Successfully imported \(count) new subscription(s)"
                                } else {
                                    importResult = "No new subscriptions were found in the OPML file"
                                }
                            case .failure(let error):
                                importResult = "Import failed: \(error.localizedDescription)"
                            }
                            showingImportResult = true
                        }
                    }
                case .failure(let error):
                    importResult = "Error selecting file: \(error.localizedDescription)"
                    showingImportResult = true
                }
            }
            .alert(isPresented: $showingImportResult) {
                Alert(
                    title: Text("OPML Import"),
                    message: Text(importResult ?? ""),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState())
    }
}
