//
//  OpenAICompatibleSettingsView.swift
//  RSSReaderApp
//
//  Settings block for the Custom Server summary provider: server URL,
//  optional API key, model (picked from the server's /models list or typed),
//  output limit and the Disable Thinking switch.
//

import SwiftUI

struct OpenAICompatibleSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isTesting = false
    @State private var connectionStatus: String?
    @State private var connectionFailed = false
    @State private var availableModels: [String] = []

    private static let maxTokenOptions = [1024, 2048, 4096, 8192, 16384]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Server")
                .font(.subheadline)
                .fontWeight(.semibold)

            Text("Use any server with an OpenAI-style API, such as oMLX, Ollama, LM Studio or llama.cpp. On iPhone and iPad, enter your Mac's network address, not 127.0.0.1.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Server URL, e.g. http://192.168.1.20:1234/v1", text: Binding(
                get: { appState.settings.openAICompatibleBaseURL },
                set: { appState.setOpenAICompatibleBaseURL($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif

            Text("Default ports: LM Studio 1234, Ollama 11434, oMLX 8000, llama.cpp 8080.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            SecureField("API key (optional)", text: Binding(
                get: { appState.settings.openAICompatibleAPIKey },
                set: { appState.setOpenAICompatibleAPIKey($0) }
            ))
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    testConnection()
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || appState.settings.openAICompatibleBaseURL.isEmpty)

                if let connectionStatus {
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundStyle(connectionFailed ? Color.red : Color.secondary)
                }
            }

            modelControls

            Picker("Max Output Tokens", selection: Binding(
                get: { appState.settings.openAICompatibleMaxTokens },
                set: { appState.setOpenAICompatibleMaxTokens($0) }
            )) {
                ForEach(Self.maxTokenOptions, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }
            .pickerStyle(.menu)

            Toggle("Disable Thinking", isOn: Binding(
                get: { appState.settings.openAICompatibleDisableThinking },
                set: { appState.setOpenAICompatibleDisableThinking($0) }
            ))
            Text("For reasoning models (Qwen 3, DeepSeek R1...). Asks the server to skip the thinking step, which is faster for summaries. Servers that don't support it ignore it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var modelControls: some View {
        let current = appState.settings.openAICompatibleModelID
        if !availableModels.isEmpty {
            Picker("Model", selection: Binding(
                get: { current },
                set: { appState.setOpenAICompatibleModelID($0) }
            )) {
                if current.isEmpty || !availableModels.contains(current) {
                    Text(current.isEmpty ? "Choose a model" : current).tag(current)
                }
                ForEach(availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .pickerStyle(.menu)
        }

        TextField("Model ID", text: Binding(
            get: { current },
            set: { appState.setOpenAICompatibleModelID($0) }
        ))
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = nil
        let snapshot = appState.settings
        Task {
            do {
                let models = try await OpenAICompatibleService.listModels(settings: snapshot)
                await MainActor.run {
                    availableModels = models
                    connectionFailed = false
                    let current = appState.settings.openAICompatibleModelID
                    if models.isEmpty {
                        connectionStatus = "Connected, but the server listed no models."
                    } else if current.isEmpty {
                        appState.setOpenAICompatibleModelID(models[0])
                        connectionStatus = "Connected. \(models.count) model(s) found."
                    } else if models.contains(current) {
                        connectionStatus = "Connected. \(current) is available."
                    } else {
                        connectionStatus = "Connected. \(models.count) model(s) found; choose one."
                    }
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    connectionFailed = true
                    connectionStatus = error.localizedDescription
                    isTesting = false
                }
            }
        }
    }
}
