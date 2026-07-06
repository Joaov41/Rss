# MLX Model Sharing on iOS: Complete Implementation Guide

This guide explains how to implement MLX model loading on iOS with support for:
- **Downloading to user-chosen folders** (iCloud Drive, local storage, USB, etc.)
- Loading from user-selected folders via Files app
- Sharing models between apps and devices

## The Problem

On iOS, apps are sandboxed and cannot access each other's files. This means:
- Each app must download its own copy of ML models (often 1-4GB each)
- Models downloaded by Python tools or Mac apps aren't accessible
- Users waste storage with duplicate model downloads

## The Solution

**User always chooses the download folder.** This gives users full control over where models are stored:
- Download to iCloud Drive for automatic sync across devices
- Download to a local folder for faster access
- Download to a USB drive for portable storage
- Share models between multiple apps via the same folder

This enables workflows where:
- Download once on iOS to iCloud Drive, use on Mac
- Download once on Mac, sync to iOS via iCloud
- Share models between multiple iOS apps via shared folder

---

## Architecture Overview

```
+---------------------------------------------------------------------+
|                        MLXLocalService                               |
+---------------------------------------------------------------------+
|  downloadModelToLocation(id:url:) -> Downloads to user-chosen folder |
|  loadModelFromDirectory(url:)     -> Loads from any folder           |
|  generateText(prompt:directory:)  -> Generate with folder model      |
+---------------------------------------------------------------------+
|  User chooses download location via Files app folder picker          |
|  Models stored at: <chosen-folder>/models/org/repo-name/             |
+---------------------------------------------------------------------+
```

---

## Complete Implementation

### 1. MLXLocalService.swift

Copy this file to your project. This is the actual implementation:

```swift
import Foundation

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
import Hub

actor MLXLocalService {
    static let shared = MLXLocalService()

    private var modelCache: [String: ModelContainer] = [:]
    private var inFlightLoads: [String: Task<ModelContainer, Error>] = [:]
    private var hasConfiguredMemory = false

    /// HubApi configured to use the appropriate cache location per platform.
    /// - macOS: Uses ~/.cache/huggingface/hub (shared with Python, mlx-lm, etc.)
    /// - iOS: Uses app's Caches directory (sandboxed, no sharing possible)
    #if os(macOS)
    private let sharedHub = HubApi(
        downloadBase: URL.homeDirectory.appending(path: ".cache/huggingface/hub")
    )
    #else
    private let sharedHub = HubApi(
        downloadBase: URL.cachesDirectory.appending(path: "huggingface")
    )
    #endif

    private func configureMemoryIfNeeded() {
        guard !hasConfiguredMemory else { return }
        // Keep MLX cache bounded so WebKit/Metal rendering can coexist with local inference.
        GPU.set(cacheLimit: 1024 * 1024 * 1024)
        hasConfiguredMemory = true
    }

    func preloadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        _ = try await loadModel(modelID: modelID, progressHandler: progressHandler)
    }

    func clearTransientCache() {
        GPU.clearCache()
    }

    func unloadModel(modelID: String) {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let task = inFlightLoads[id] {
            task.cancel()
            inFlightLoads[id] = nil
        }
        modelCache[id] = nil
        GPU.clearCache()
    }

    func unloadAllModels() {
        for (_, task) in inFlightLoads {
            task.cancel()
        }
        inFlightLoads.removeAll()
        modelCache.removeAll()
        GPU.clearCache()
    }

    func generateText(
        prompt: String,
        modelID: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        configureMemoryIfNeeded()
        let container = try await loadModel(modelID: modelID)
        return try await generateWithContainer(container, prompt: prompt, maxOutputTokens: maxOutputTokens, maxContextTokens: maxContextTokens)
    }

    /// Generate text using a model loaded from a local directory.
    /// Use this when loading models from user-selected folders (e.g., via Files app on iOS).
    func generateText(
        prompt: String,
        modelDirectory: URL,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        configureMemoryIfNeeded()
        let container = try await loadModelFromDirectory(modelDirectory)
        return try await generateWithContainer(container, prompt: prompt, maxOutputTokens: maxOutputTokens, maxContextTokens: maxContextTokens)
    }

    private func generateWithContainer(
        _ container: ModelContainer,
        prompt: String,
        maxOutputTokens: Int,
        maxContextTokens: Int?
    ) async throws -> String {
        let startTime = Date()
        let systemPrompt = "You are a helpful assistant."
        let chat: [Chat.Message] = [
            .system(systemPrompt),
            .user(prompt),
        ]
        let userInput = UserInput(chat: chat)
        print("⏱️ [MLX] Starting generation (maxTokens: \(maxOutputTokens))")

        let stream = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(
                maxTokens: maxOutputTokens,
                maxKVSize: maxContextTokens,
                temperature: 0.2,
                topP: 0.95
            )
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var output = ""
        var tokenCount = 0
        for await token in stream {
            if Task.isCancelled { throw CancellationError() }
            if let chunk = token.chunk {
                output += chunk
                tokenCount += 1
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let tokensPerSecond = elapsed > 0 ? Double(tokenCount) / elapsed : 0
        print("✅ [MLX] Generated \(tokenCount) tokens in \(String(format: "%.1f", elapsed))s (\(String(format: "%.1f", tokensPerSecond)) tok/s)")

        return output
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadModel(
        modelID: String,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        configureMemoryIfNeeded()
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        if let cached = modelCache[id] {
            return cached
        }

        if let task = inFlightLoads[id] {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            let configuration = LLMRegistry.shared.configuration(id: id)
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: sharedHub,
                configuration: configuration,
                progressHandler: progressHandler
            )
            return container
        }

        inFlightLoads[id] = task
        do {
            let container = try await task.value
            modelCache[id] = container
            inFlightLoads[id] = nil
            return container
        } catch {
            inFlightLoads[id] = nil
            throw error
        }
    }

    /// Load a model from a local directory (e.g., user-selected via Files app).
    /// Handles security-scoped resource access for iOS sandboxing.
    private func loadModelFromDirectory(_ directory: URL) async throws -> ModelContainer {
        configureMemoryIfNeeded()

        let cacheKey = directory.absoluteString
        if let cached = modelCache[cacheKey] {
            print("🚀 [MLX] Using cached model")
            return cached
        }
        print("⏳ [MLX] Loading model from disk...")

        if let task = inFlightLoads[cacheKey] {
            return try await task.value
        }

        let task = Task<ModelContainer, Error> {
            // Handle security-scoped resources (required for iOS file picker URLs)
            let didStartAccessing = directory.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    directory.stopAccessingSecurityScopedResource()
                }
            }

            // Verify the directory contains required model files
            let configPath = directory.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                throw NSError(
                    domain: "MLXLocalService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid model directory: missing config.json"]
                )
            }

            let configuration = ModelConfiguration(directory: directory)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration,
                progressHandler: { _ in }
            )
            return container
        }

        inFlightLoads[cacheKey] = task
        do {
            let container = try await task.value
            modelCache[cacheKey] = container
            inFlightLoads[cacheKey] = nil
            return container
        } catch {
            inFlightLoads[cacheKey] = nil
            throw error
        }
    }

    /// Preload a model from a local directory for faster first inference.
    func preloadModelFromDirectory(_ directory: URL) async throws {
        _ = try await loadModelFromDirectory(directory)
    }

    /// Unload a model that was loaded from a local directory.
    func unloadModelFromDirectory(_ directory: URL) {
        let cacheKey = directory.absoluteString
        if let task = inFlightLoads[cacheKey] {
            task.cancel()
            inFlightLoads[cacheKey] = nil
        }
        modelCache[cacheKey] = nil
        GPU.clearCache()
    }

    /// Download a model to a custom location (e.g., iCloud Drive for sharing).
    func downloadModelToLocation(
        modelID: String,
        location: URL,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw NSError(
                domain: "MLXLocalService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing Hugging Face model id."]
            )
        }

        // Create a HubApi with the custom download location
        let customHub = HubApi(downloadBase: location)

        // Get the model configuration
        let configuration = LLMRegistry.shared.configuration(id: id)

        // Download to the custom location (this just downloads, doesn't load into memory)
        _ = try await LLMModelFactory.shared.loadContainer(
            hub: customHub,
            configuration: configuration,
            progressHandler: progressHandler
        )
    }
}
#else
// Fallback for builds without MLX
actor MLXLocalService {
    static let shared = MLXLocalService()

    func preloadModel(modelID: String, progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        throw NSError(domain: "MLXLocalService", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."])
    }

    func clearTransientCache() {}
    func unloadModel(modelID: String) {}
    func unloadAllModels() {}

    func generateText(prompt: String, modelID: String, maxOutputTokens: Int, maxContextTokens: Int?) async throws -> String {
        throw NSError(domain: "MLXLocalService", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."])
    }

    func generateText(prompt: String, modelDirectory: URL, maxOutputTokens: Int, maxContextTokens: Int?) async throws -> String {
        throw NSError(domain: "MLXLocalService", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."])
    }

    func preloadModelFromDirectory(_ directory: URL) async throws {
        throw NSError(domain: "MLXLocalService", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."])
    }

    func unloadModelFromDirectory(_ directory: URL) {}

    func downloadModelToLocation(modelID: String, location: URL, progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }) async throws {
        throw NSError(domain: "MLXLocalService", code: 1, userInfo: [NSLocalizedDescriptionKey: "MLX Local is unavailable in this build (missing MLX packages)."])
    }
}
#endif
```

---

### 2. Download UI (Single Button, Always Asks for Folder)

Add these state variables to your settings view:

```swift
// MLX Local model management
@State private var isLoadingMLXModel = false
@State private var mlxDownloadProgress: Progress? = nil
@State private var mlxLoadError: String? = nil
@State private var showDownloadLocationPicker = false

// Store the selected model ID (use your own storage mechanism)
@AppStorage("mlxModelID") private var mlxModelID = "mlx-community/Llama-3.2-1B-Instruct-4bit"
```

Add the download button UI:

```swift
// Model ID input field
TextField("Model ID", text: $mlxModelID)
    .textFieldStyle(.roundedBorder)

// Single download button - always asks user to choose folder
Button(action: {
    showDownloadLocationPicker = true
}) {
    HStack {
        if isLoadingMLXModel {
            ProgressView()
                .scaleEffect(0.8)
        } else {
            Image(systemName: "arrow.down.circle")
        }
        Text("Download Model")
    }
}
.buttonStyle(.borderedProminent)
.disabled(isLoadingMLXModel)

// Progress indicator
if let progress = mlxDownloadProgress {
    ProgressView(progress)
}

// Error display
if let mlxLoadError {
    Text(mlxLoadError)
        .font(.caption)
        .foregroundColor(.red)
}

// Manage Models button
Button(action: {
    isPresentingMLXModelManager = true
}) {
    HStack {
        Image(systemName: "folder")
        Text("Manage Models")
    }
}
```

Add the file importer modifier to your view:

```swift
.fileImporter(
    isPresented: $showDownloadLocationPicker,
    allowedContentTypes: [.folder],
    allowsMultipleSelection: false
) { result in
    switch result {
    case .success(let urls):
        guard let url = urls.first else { return }
        downloadModel(to: url)
    case .failure(let error):
        mlxLoadError = error.localizedDescription
    }
}
```

Add the download function:

```swift
private func downloadModel(to location: URL) {
    mlxLoadError = nil
    mlxDownloadProgress = nil
    isLoadingMLXModel = true

    Task {
        defer {
            Task { @MainActor in
                isLoadingMLXModel = false
            }
        }
        do {
            let modelID = mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)

            // Access security-scoped resource for the selected folder
            guard location.startAccessingSecurityScopedResource() else {
                throw NSError(
                    domain: "MLXDownload",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot access the selected folder"]
                )
            }
            defer { location.stopAccessingSecurityScopedResource() }

            try await MLXLocalService.shared.downloadModelToLocation(
                modelID: modelID,
                location: location,
                progressHandler: { progress in
                    Task { @MainActor in
                        mlxDownloadProgress = progress
                    }
                }
            )

            // Model is now at: location/models/org/repo-name
            // Auto-set as the active model
            let modelPath = location.appending(path: "models/\(modelID)")
            await MainActor.run {
                UserDefaults.standard.set(modelPath.path, forKey: "MLXExternalModelPath")
                // Store "external:<path>" as the model ID to indicate folder-based loading
                mlxModelID = "external:\(modelPath.path)"
            }

        } catch {
            await MainActor.run {
                mlxLoadError = error.localizedDescription
            }
        }
    }
}
```

---

### 3. ManageMLXModelsView - Model Selector

A simple view that allows users to select a model folder from the Files app:

```swift
struct ManageMLXModelsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String? = nil
    @State private var showFolderPicker = false

    // Your model ID binding - adjust to your storage mechanism
    @AppStorage("mlxModelID") private var mlxModelID = ""

    // Keys for storing model bookmark
    private let modelBookmarkKey = "MLXExternalModelBookmark"
    private let modelPathKey = "MLXExternalModelPath"

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let modelPath = UserDefaults.standard.string(forKey: modelPathKey) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: modelPath).lastPathComponent)
                                    .font(.body)
                                Text("Selected")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                clearModel()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("No model selected")
                            .foregroundColor(.secondary)
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Select Model from Files", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Selected Model")
                } footer: {
                    Text("Select a model folder from iCloud Drive, local storage, or external drives. Use \"Download Model\" in Settings to download new models to your preferred location.")
                }
            }
            .navigationTitle("Manage Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderSelection(result)
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error.")
            }
        }
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access the selected folder"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Validate it contains a model
            let configPath = url.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                errorMessage = "Invalid model folder: missing config.json. Please select the folder containing the model files."
                return
            }

            // Save bookmark for persistence
            do {
                #if os(iOS)
                let bookmarkData = try url.bookmarkData(options: .minimalBookmark)
                #else
                let bookmarkData = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                #endif
                UserDefaults.standard.set(bookmarkData, forKey: modelBookmarkKey)
                UserDefaults.standard.set(url.path, forKey: modelPathKey)

                // Set as the active model
                mlxModelID = "external:\(url.path)"
            } catch {
                errorMessage = "Failed to save folder bookmark: \(error.localizedDescription)"
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func clearModel() {
        UserDefaults.standard.removeObject(forKey: modelBookmarkKey)
        UserDefaults.standard.removeObject(forKey: modelPathKey)
        mlxModelID = ""
    }
}
```

---

### 4. Using the Selected Model for Generation

When generating text, restore the bookmark and load from the model directory:

```swift
func generateWithSelectedModel(prompt: String) async throws -> String {
    let maxOutputTokens = 512
    let maxContextTokens: Int? = nil

    // Restore bookmark for file access
    guard let bookmarkData = UserDefaults.standard.data(forKey: "MLXExternalModelBookmark") else {
        throw NSError(domain: "MLX", code: 1, userInfo: [NSLocalizedDescriptionKey: "No model selected. Please select a model in Manage Models."])
    }

    var isStale = false
    #if os(iOS)
    let modelURL = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    #else
    let modelURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    #endif

    if isStale {
        throw NSError(domain: "MLX", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model bookmark is stale. Please re-select the model folder in Manage Models."])
    }

    return try await MLXLocalService.shared.generateText(
        prompt: prompt,
        modelDirectory: modelURL,
        maxOutputTokens: maxOutputTokens,
        maxContextTokens: maxContextTokens
    )
}
```

---

## How It Works

### Download Flow

When user taps "Download Model":

```
1. User taps "Download Model" button
                    |
                    v
2. Files picker opens - user chooses destination folder
   (e.g., iCloud Drive/MLX-Models/ or On My iPad/Models/)
                    |
                    v
3. App creates HubApi with selected folder as downloadBase
                    |
                    v
4. Model downloads to: <selected-folder>/models/org/repo-name/
                    |
                    v
5. If iCloud: Syncs to other devices automatically
                    |
                    v
6. Model is auto-selected for use
   Other apps can load from same folder via Manage Models!
```

### Folder Structure After Download

```
YourFolder/
└── models/
    └── mlx-community/
        └── Llama-3.2-1B-Instruct-4bit/
            ├── config.json
            ├── tokenizer.json
            ├── tokenizer_config.json
            └── model.safetensors (or sharded files)
```

### Security-Scoped Resources

iOS requires special handling for files outside the app sandbox:

```swift
// 1. Start access before any file operations
let didStart = url.startAccessingSecurityScopedResource()

// 2. Do your work
try await loadModel(from: url)

// 3. Stop access when done
if didStart {
    url.stopAccessingSecurityScopedResource()
}
```

### Bookmark Persistence

Save bookmarks so users don't have to re-select folders after app restart:

```swift
// Save bookmark
#if os(iOS)
let bookmarkData = try url.bookmarkData(options: .minimalBookmark)
#else
let bookmarkData = try url.bookmarkData(options: [.withSecurityScope])
#endif
UserDefaults.standard.set(bookmarkData, forKey: "modelBookmark")

// Restore bookmark
var isStale = false
let restoredURL = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
if isStale {
    // Need to re-select the folder
}
```

---

## Supported Download/Load Locations

| Location | Selectable | Notes |
|----------|------------|-------|
| **iCloud Drive** | Yes | Syncs across devices, recommended for sharing |
| **On My iPad** | Yes | Local storage, fast access |
| **USB Drive** | Yes | Portable, via Files app |
| **SMB Share** | Yes | Network storage |
| **Google Drive** | Yes | If app installed |
| **Dropbox** | Yes | If app installed |

---

## User Workflow Examples

### Example 1: Download to iCloud for Sharing

1. **On iOS**: Tap "Download Model"
2. **Files picker opens**: Select iCloud Drive > MLX-Models
3. **Wait** for download to complete
4. **On Mac**: Model appears in `~/Library/Mobile Documents/com~apple~CloudDocs/MLX-Models/`
5. **Use on Mac** without re-downloading!

### Example 2: Use Model Downloaded on Mac

1. **On Mac**: Download model with Python
   ```bash
   mlx_lm.generate --model mlx-community/Llama-3.2-1B-4bit --prompt "Hi"
   ```
2. **Copy to iCloud**:
   ```bash
   cp -r ~/.cache/huggingface/hub/models--mlx-community--Llama-3.2-1B-4bit/snapshots/*/ \
         ~/Library/Mobile\ Documents/com~apple~CloudDocs/MLX-Models/Llama-3.2-1B-4bit/
   ```
3. **On iOS**: Tap "Manage Models" > "Select Model from Files"
4. **Navigate** to iCloud > MLX-Models > Llama-3.2-1B-4bit
5. **Use immediately**!

### Example 3: External USB Drive

1. **Copy model** to USB drive
2. **Connect** USB to iPad
3. **Tap** "Manage Models"
4. **Tap** "Select Model from Files"
5. **Navigate** to USB drive in Files
6. **Select** the model folder (containing config.json)
7. **Load** directly from USB (no copy needed)

---

## Platform Behavior Summary

| Feature | iOS | macOS | iPad App on Mac |
|---------|-----|-------|-----------------|
| User chooses download folder | Yes | Yes | Yes |
| Load from Files picker | Yes | Yes | Yes |
| iCloud sync | Yes | Yes | Yes |
| USB drive support | Yes | Yes | Yes |
| Local folder support | Yes | Yes | Yes |

---

## Performance Optimization: GPU Cache

### Keep Model Cached Between Generations

**Important:** Do NOT call `GPU.clearCache()` after each generation. This was a common mistake that caused the model to reload from disk on every inference, making every run feel like a "cold start."

```swift
// ❌ BAD - clears model after every generation, causes slow performance
func generateText(...) async throws -> String {
    configureMemoryIfNeeded()
    defer { GPU.clearCache() }  // DON'T DO THIS
    let container = try await loadModelFromDirectory(modelDirectory)
    return try await generateWithContainer(...)
}

// ✅ GOOD - model stays cached in memory for fast subsequent generations
func generateText(...) async throws -> String {
    configureMemoryIfNeeded()
    let container = try await loadModelFromDirectory(modelDirectory)
    return try await generateWithContainer(...)
}
```

### When to Clear GPU Cache

Only clear the GPU cache when:
- User explicitly unloads a model (`unloadModel`, `unloadAllModels`)
- App receives memory warning
- User switches to a different model

The `unloadModel` and `unloadAllModels` functions already call `GPU.clearCache()` appropriately.

### Debug Logging

The implementation includes debug logging to verify caching is working:

```
⏳ [MLX] Loading model from disk...     <- First run, loads from storage
⏱️ [MLX] Starting generation (maxTokens: 512)
✅ [MLX] Generated 512 tokens in 8.6s (59.9 tok/s)

🚀 [MLX] Using cached model             <- Subsequent runs use cache
⏱️ [MLX] Starting generation (maxTokens: 512)
✅ [MLX] Generated 512 tokens in 8.5s (60.2 tok/s)
```

If you see "Loading model from disk" on every generation, something is clearing the cache incorrectly.

### Expected Performance

On Apple Silicon devices with a small 4-bit quantized model (e.g., Llama-3.2-1B-4bit):
- **iPad M-series**: ~60 tokens/second
- **iPhone A17+**: ~40-50 tokens/second
- **Mac M1/M2/M3**: ~60-80 tokens/second

The "slowness" is often just the time it takes to generate many tokens. At 60 tok/s:
- 256 tokens ≈ 4 seconds
- 512 tokens ≈ 8.5 seconds
- 896 tokens ≈ 15 seconds

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Cannot access folder" | Re-select the folder in Files picker |
| "Missing config.json" | Select the folder containing config.json, not a parent |
| Bookmark is stale | Folder was moved/deleted, re-select |
| Download fails to iCloud | Check iCloud storage space |
| Model won't load from USB | USB may be too slow, try copying to local storage |
| Out of memory | Try a smaller 4-bit quantized model |
| Slow on every run | Check you're not calling `GPU.clearCache()` after generation |
| "Loading from disk" every time | Model cache is being cleared - see GPU Cache section above |

---

## Requirements

- iOS 17.0+ / macOS 14.0+
- Xcode 15.0+
- Device with Apple Silicon (M1/M2/M3/M4 or A14+)
- MLX Swift packages:
  - `mlx-swift`
  - `mlx-swift-examples` (for MLXLLM, MLXLMCommon)
  - `swift-transformers` (for Hub)
