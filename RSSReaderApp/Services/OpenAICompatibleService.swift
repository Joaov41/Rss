//
//  OpenAICompatibleService.swift
//  RSSReaderApp
//
//  Client for any server that speaks the OpenAI chat completions API: oMLX,
//  Ollama, LM Studio, llama.cpp, vLLM and hosted OpenAI-compatible services.
//  Ported from the AI Assistant app's OpenAICompatibleLocalProvider (text only).
//

import Foundation

enum OpenAICompatibleEndpoint {
    /// Accepts "host:port", "http://host:port", ".../v1" or a full ".../chat/completions" URL.
    static func normalizedBaseURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OpenAICompatibleError.missingBaseURL
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            throw OpenAICompatibleError.invalidBaseURL(rawValue)
        }

        var pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        while pathParts.count >= 2,
              pathParts[pathParts.count - 2].lowercased() == "chat",
              pathParts[pathParts.count - 1].lowercased() == "completions" {
            pathParts.removeLast(2)
        }
        if pathParts.last?.lowercased() == "models" {
            pathParts.removeLast()
        }

        components.scheme = scheme
        components.path = pathParts.isEmpty ? "" : "/" + pathParts.joined(separator: "/")
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw OpenAICompatibleError.invalidBaseURL(rawValue)
        }
        return url
    }

    static func chatCompletionsURL(from rawValue: String) throws -> URL {
        append("chat/completions", to: try normalizedBaseURL(from: rawValue))
    }

    static func modelsURL(from rawValue: String) throws -> URL {
        append("models", to: try normalizedBaseURL(from: rawValue))
    }

    private static func append(_ suffix: String, to baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(suffix)
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url ?? baseURL.appendingPathComponent(suffix)
    }
}

enum OpenAICompatibleError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL(String)
    case missingModelID
    case serverUnavailable(URL)
    case httpError(Int, String)
    case decodingFailed(String)
    case emptyResponse
    case reasoningOnly
    case outputLimitWithoutAnswer
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "Custom Server server URL is empty. Set it in Settings → Summary Provider."
        case .invalidBaseURL(let value):
            return "Custom Server server URL is invalid: \(value)"
        case .missingModelID:
            return "No Custom Server model chosen. Tap Test Connection in Settings and pick a model."
        case .serverUnavailable(let url):
            return "The Custom Server server isn't reachable at \(url.absoluteString). Check that it's running and that this device can reach it."
        case .httpError(let statusCode, let message):
            return "Custom Server server returned HTTP \(statusCode): \(message)"
        case .decodingFailed(let message):
            return "Custom Server response could not be read: \(message)"
        case .emptyResponse:
            return "Custom Server server returned an empty response."
        case .reasoningOnly:
            return "The model returned its reasoning but no answer. Turn on Disable Thinking or raise Max Output Tokens."
        case .outputLimitWithoutAnswer:
            return "The model hit the output-token limit before answering. Raise Max Output Tokens in Settings."
        case .requestFailed(let message):
            return "Custom Server request failed: \(message)"
        }
    }
}

enum OpenAICompatibleService {
    static let displayName = "Custom Server"

    /// One chat completion. Runs under the background task like every other provider.
    static func generate(prompt: String, settings: AppSettings) async throws -> String {
        let modelID = settings.openAICompatibleModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else { throw OpenAICompatibleError.missingModelID }

        let baseURL = try OpenAICompatibleEndpoint.normalizedBaseURL(from: settings.openAICompatibleBaseURL)
        var request = URLRequest(url: try OpenAICompatibleEndpoint.chatCompletionsURL(from: settings.openAICompatibleBaseURL))
        request.httpMethod = "POST"
        // Local models can take minutes on long prompts, especially while the model loads.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request, apiKey: settings.openAICompatibleAPIKey)

        let body = ChatCompletionRequest(
            model: modelID,
            messages: [ChatMessage(role: "user", content: prompt)],
            temperature: 0.3,
            maxTokens: AppSettings.normalizedOpenAICompatibleMaxTokens(settings.openAICompatibleMaxTokens),
            stream: false,
            chatTemplateKwargs: settings.openAICompatibleDisableThinking
                ? ChatTemplateKwargs(enableThinking: false)
                : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        return try await withAIBackgroundTask("Generating with \(modelID)") {
            let (data, response) = try await send(request, baseURL: baseURL)
            try validate(response, data: data)
            return try decodeCompletion(data)
        }
    }

    /// Model IDs from the server's /models endpoint.
    static func listModels(settings: AppSettings) async throws -> [String] {
        let baseURL = try OpenAICompatibleEndpoint.normalizedBaseURL(from: settings.openAICompatibleBaseURL)
        var request = URLRequest(url: try OpenAICompatibleEndpoint.modelsURL(from: settings.openAICompatibleBaseURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        applyAuthorization(to: &request, apiKey: settings.openAICompatibleAPIKey)

        let (data, response) = try await send(request, baseURL: baseURL)
        try validate(response, data: data)
        guard let models = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw OpenAICompatibleError.decodingFailed("The /models response was not in OpenAI format.")
        }
        var seen = Set<String>()
        return (models.data ?? []).compactMap { model in
            guard let id = model.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return id
        }
    }

    // MARK: - Request plumbing

    private static func applyAuthorization(to request: inout URLRequest, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private static func send(_ request: URLRequest, baseURL: URL) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw OpenAICompatibleError.requestFailed("The server timed out. It may still be loading the model.")
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw OpenAICompatibleError.serverUnavailable(baseURL)
            default:
                throw OpenAICompatibleError.requestFailed(error.localizedDescription)
            }
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.decodingFailed("The server did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.httpError(http.statusCode, serverErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
    }

    private static func decodeCompletion(_ data: Data) throws -> String {
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw OpenAICompatibleError.decodingFailed(error.localizedDescription)
        }
        guard let choice = decoded.choices.first else {
            throw OpenAICompatibleError.emptyResponse
        }
        let raw = choice.message?.content?.text ?? choice.text ?? ""
        let text = strippingThinking(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if choice.finishReason == "length" { throw OpenAICompatibleError.outputLimitWithoutAnswer }
            if choice.message?.reasoningContent?.isEmpty == false || raw.contains("<think>") {
                throw OpenAICompatibleError.reasoningOnly
            }
            throw OpenAICompatibleError.emptyResponse
        }
        return text
    }

    /// Reasoning models served without a reasoning parser put their thinking inline as <think>…</think>.
    static func strippingThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Unclosed: the output stopped mid-thought, so nothing after it is an answer.
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        // Some templates open the thought in the prompt, so the reply starts mid-thought.
        if let close = result.range(of: "</think>") {
            result.removeSubrange(result.startIndex..<close.upperBound)
        }
        return result
    }

    private static func serverErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data),
           let message = decoded.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.count > 500 ? String(raw.prefix(500)) + "..." : raw
    }

    // MARK: - Wire types

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
        let maxTokens: Int
        let stream: Bool
        let chatTemplateKwargs: ChatTemplateKwargs?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }

    private struct ChatTemplateKwargs: Encodable {
        let enableThinking: Bool

        enum CodingKeys: String, CodingKey {
            case enableThinking = "enable_thinking"
        }
    }

    private struct ChatMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatCompletionResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message?
            let text: String?
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message, text
                case finishReason = "finish_reason"
            }
        }

        struct Message: Decodable {
            let content: ResponseContent?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
            }
        }
    }

    private enum ResponseContent: Decodable {
        case text(String)
        case parts([Part])

        var text: String {
            switch self {
            case .text(let text): return text
            case .parts(let parts): return parts.compactMap(\.text).joined(separator: "\n")
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .parts(try container.decode([Part].self))
            }
        }

        struct Part: Decodable {
            let text: String?
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [Model]?

        struct Model: Decodable {
            let id: String?
        }
    }

    private struct ErrorResponse: Decodable {
        let error: ErrorBody?

        struct ErrorBody: Decodable {
            let message: String?
        }
    }
}
