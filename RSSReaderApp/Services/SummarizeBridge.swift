import Foundation
import Darwin
import Network
import Security

enum RSSSummarizeGatewayConfig {
    static let codexModel = "cli/codex/gpt-5.5"
    static let serviceTier = "fast"
    static let reasoningEffort = "low"
    static let textVerbosity = "low"
    static let outputLength = "short"
    static let bonjourServiceType = "_rss-sum._tcp"
}

struct RSSSummarizeDaemonConfiguration {
    let host: String
    let port: Int
    let token: String
    let model: String

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}

struct RSSSummarizeBridgeConfiguration {
    let host: String
    let port: Int
    let secret: String
}

struct FMPCCGatewayConfiguration {
    let host: String
    let port: Int
    let token: String
    let model: String

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}

enum RSSSummarizeProviderError: LocalizedError {
    case missingDaemonToken
    case missingBridgeSecret
    case invalidPort(Int)
    case emptyResponse
    case badStatus(Int, String)
    case bridgeUnavailable
    case bridgeRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingDaemonToken:
            return "Summarize daemon token is not configured. On Mac, set the daemon token or install ~/.summarize/daemon.json. On iPad, configure the bridge secret."
        case .missingBridgeSecret:
            return "Summarize bridge secret/pass is not configured."
        case .invalidPort(let port):
            return "Summarize port \(port) is invalid."
        case .emptyResponse:
            return "Summarize returned an empty response."
        case .badStatus(let code, let body):
            return "Summarize API error \(code): \(body)"
        case .bridgeUnavailable:
            return "Summarize bridge was not found. Keep the Mac app open on the same network or set the Mac host/IP."
        case .bridgeRejected(let message):
            return message
        }
    }
}

enum FMPCCGatewayError: LocalizedError {
    case missingHost
    case missingToken
    case invalidPort(Int)
    case emptyResponse
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "Apple PCC Gateway host is not configured. Use 127.0.0.1 in Simulator or your Mac LAN IP on iPhone/iPad."
        case .missingToken:
            return "Apple PCC Gateway token is not configured."
        case .invalidPort(let port):
            return "Apple PCC Gateway port \(port) is invalid."
        case .emptyResponse:
            return "Apple PCC Gateway returned an empty response."
        case .badStatus(let code, let body):
            if code == 401 || code == 403 {
                return "Apple PCC Gateway rejected the token."
            }
            return "Apple PCC Gateway error \(code): \(body)"
        }
    }
}

enum RSSSummarizeKeychain {
    static let daemonTokenKey = "summarize_daemon_token"
    static let bridgeSecretKey = "summarize_bridge_secret"
    static let pccGatewayTokenKey = "pcc_gateway_token"

    private static let service = "com.joaovalente.RSSReaderApp.summarize"
    private static let lock = NSLock()
    private static var loadedAccounts = Set<String>()
    private static var cachedStrings: [String: String] = [:]

    static func string(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        if loadedAccounts.contains(account) {
            return cachedStrings[account]
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        loadedAccounts.insert(account)
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            cachedStrings.removeValue(forKey: account)
            return nil
        }
        cachedStrings[account] = value
        return value
    }

    static func set(_ value: String, for account: String) {
        let sanitized = AppSettings.sanitizedSummarizeSecret(value)
        lock.lock()
        defer { lock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        loadedAccounts.insert(account)
        guard !sanitized.isEmpty, let data = sanitized.data(using: .utf8) else {
            cachedStrings.removeValue(forKey: account)
            SecItemDelete(query as CFDictionary)
            return
        }

        cachedStrings[account] = sanitized
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
}

enum RSSSummarizeDaemonTokenResolver {
    static func sanitized(_ rawValue: String?) -> String {
        AppSettings.sanitizedSummarizeSecret(rawValue ?? "")
    }

    static func localDaemonConfigToken() -> String? {
        #if os(macOS)
        for path in localDaemonConfigPaths() {
            guard
                let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = object["token"] as? String
            else {
                continue
            }

            let sanitized = sanitized(token)
            if !sanitized.isEmpty { return sanitized }
        }
        return nil
        #else
        return nil
        #endif
    }

    #if os(macOS)
    private static func localDaemonConfigPaths() -> [String] {
        var paths: [String] = []

        func append(_ path: String?) {
            guard let path, !path.isEmpty, !paths.contains(path) else { return }
            paths.append(path)
        }

        if let realHome = realUserHomeDirectory() {
            append(URL(fileURLWithPath: realHome).appendingPathComponent(".summarize/daemon.json").path)
        }
        append(NSString(string: "~/.summarize/daemon.json").expandingTildeInPath)

        return paths
    }

    private static func realUserHomeDirectory() -> String? {
        guard let passwordRecord = getpwuid(getuid()),
              let homeDirectory = passwordRecord.pointee.pw_dir else {
            return nil
        }
        return String(cString: homeDirectory)
    }
    #endif

    static func effectiveToken(preferred: String?, fallback: String? = nil) -> String {
        #if os(macOS)
        if let daemonConfigToken = localDaemonConfigToken(), !daemonConfigToken.isEmpty {
            return daemonConfigToken
        }
        #endif

        let preferredToken = sanitized(preferred)
        if !preferredToken.isEmpty { return preferredToken }

        let fallbackToken = sanitized(fallback)
        if !fallbackToken.isEmpty { return fallbackToken }

        return ""
    }
}

final class RSSSummarizeDaemonHTTPClient: @unchecked Sendable {
    private let configuration: RSSSummarizeDaemonConfiguration
    private let session: URLSession

    init(configuration: RSSSummarizeDaemonConfiguration) {
        self.configuration = configuration

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 120
        sessionConfiguration.timeoutIntervalForResource = 300
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func ping() async throws -> String {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/ping"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body?.isEmpty == false ? body! : "Connected"
    }

    func generate(prompt: String, onPartial: ((String) -> Void)? = nil) async throws -> String {
        let url = configuration.baseURL
            .appendingPathComponent("v1/agent")
            .appending(queryItems: [URLQueryItem(name: "format", value: "json")])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.addValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AgentRequest(
            url: "https://rssreader.local/summary",
            title: "RSSReaderApp",
            // The daemon injects pageContent into its system prompt; keep the full
            // request only in messages so the model context is not duplicated.
            pageContent: "",
            messages: [
                AgentMessage(
                    role: "user",
                    content: prompt,
                    timestamp: Date().timeIntervalSince1970 * 1000
                )
            ],
            automationEnabled: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let output = try decodeAgentOutput(data)
        onPartial?(output)
        return output
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            if httpResponse.statusCode == 401 || body.contains("\"unauthorized\"") {
                throw RSSSummarizeProviderError.badStatus(
                    httpResponse.statusCode,
                    "Summarize daemon rejected the token. RSSReaderApp will use the token from ~/.summarize/daemon.json on Mac; restart the app or clear the saved daemon token if this persists."
                )
            }
            throw RSSSummarizeProviderError.badStatus(httpResponse.statusCode, body)
        }
    }

    private func decodeAgentOutput(_ data: Data) throws -> String {
        if let response = try? JSONDecoder().decode(AgentResponse.self, from: data),
           let output = response.output {
            return output
        }

        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }

        throw RSSSummarizeProviderError.emptyResponse
    }

    private struct AgentRequest: Encodable {
        let url: String
        let title: String
        let pageContent: String
        let messages: [AgentMessage]
        let automationEnabled: Bool
    }

    private struct AgentMessage: Encodable {
        let role: String
        let content: String
        let timestamp: Double
    }

    private struct AgentResponse: Decodable {
        let assistant: Assistant?
        let content: String?
        let text: String?
        let summary: String?
        let rawOutput: String?

        enum CodingKeys: String, CodingKey {
            case assistant
            case content
            case text
            case summary
            case rawOutput = "output"
        }

        var output: String? {
            [
                assistant?.content,
                assistant?.text,
                content,
                text,
                summary,
                rawOutput
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        }
    }

    private struct Assistant: Decodable {
        let content: String?
        let text: String?
    }
}

final class FMPCCGatewayClient: @unchecked Sendable {
    private let configuration: FMPCCGatewayConfiguration
    private let session: URLSession

    init(configuration: FMPCCGatewayConfiguration) {
        self.configuration = configuration

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 120
        sessionConfiguration.timeoutIntervalForResource = 300
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func health() async throws -> String {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.addValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body?.isEmpty == false ? body! : "Connected"
    }

    func generate(prompt: String) async throws -> String {
        let url = configuration.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.addValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: configuration.model,
                messages: [ChatMessage(role: "user", content: prompt)],
                stream: false
            )
        )

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        if let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
           let output = decoded.output {
            return output
        }

        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }

        throw FMPCCGatewayError.emptyResponse
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = decodeErrorBody(data)
            throw FMPCCGatewayError.badStatus(httpResponse.statusCode, body)
        }
    }

    private func decodeErrorBody(_ data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
           let message = decoded.error?.message.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Unknown error"
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatCompletionResponse: Decodable {
        let choices: [Choice]?
        let error: ErrorBody?
        let text: String?
        let content: String?
        let summary: String?

        var output: String? {
            [
                choices?.first?.message.content,
                text,
                content,
                summary
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        }
    }

    private struct Choice: Decodable {
        let message: ChatMessage
    }

    private struct ErrorBody: Decodable {
        let message: String
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct RSSSummarizeBridgeRequest: Codable {
    let kind: Kind
    let secret: String
    let prompt: String?

    enum Kind: String, Codable {
        case ping
        case generate
    }
}

private struct RSSSummarizeBridgeResponse: Codable {
    let ok: Bool
    let text: String?
    let error: String?
}

private enum RSSSummarizeTimeout {
    struct Error: LocalizedError {
        let seconds: TimeInterval
        var errorDescription: String? { "Summarize request timed out after \(Int(seconds)) seconds." }
    }

    static func run<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Error(seconds: seconds)
            }

            guard let value = try await group.next() else {
                throw Error(seconds: seconds)
            }
            group.cancelAll()
            return value
        }
    }
}

private final class RSSBridgeContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let connection: NWConnection?
    private let continuation: CheckedContinuation<T, Error>

    init(connection: NWConnection? = nil, continuation: CheckedContinuation<T, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard markResumed() else { return }
        connection?.cancel()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard markResumed() else { return }
        connection?.cancel()
        continuation.resume(throwing: error)
    }

    private func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

private final class RSSValueContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<T, Never>

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}

final class RSSSummarizeBridgeClient: @unchecked Sendable {
    private let configuration: RSSSummarizeBridgeConfiguration
    private let queue = DispatchQueue(label: "RSSReaderApp.summarize.bridge.client")

    init(configuration: RSSSummarizeBridgeConfiguration) {
        self.configuration = configuration
    }

    func ping() async throws -> String {
        let response = try await send(kind: .ping, prompt: nil, timeout: 10)
        guard response.ok else {
            throw RSSSummarizeProviderError.bridgeRejected(response.error ?? "Summarize bridge rejected the ping.")
        }
        return response.text?.isEmpty == false ? response.text! : "Connected"
    }

    func generate(prompt: String, onPartial: ((String) -> Void)? = nil) async throws -> String {
        let response = try await send(kind: .generate, prompt: prompt, timeout: 300)
        guard response.ok, let text = response.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw RSSSummarizeProviderError.bridgeRejected(response.error ?? "Summarize bridge returned an empty response.")
        }
        onPartial?(text)
        return text
    }

    private func send(kind: RSSSummarizeBridgeRequest.Kind, prompt: String?, timeout: TimeInterval) async throws -> RSSSummarizeBridgeResponse {
        let request = RSSSummarizeBridgeRequest(kind: kind, secret: configuration.secret, prompt: prompt)
        let endpoint = try await resolveEndpoint()

        return try await RSSSummarizeTimeout.run(seconds: timeout) {
            try await self.send(request: request, endpoint: endpoint)
        }
    }

    private func resolveEndpoint() async throws -> NWEndpoint {
        if let discovered = await discoverBridgeEndpoint(timeout: 1.5) {
            return discovered
        }

        let host = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(configuration.port)) else {
            throw RSSSummarizeProviderError.bridgeUnavailable
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    private func discoverBridgeEndpoint(timeout: TimeInterval) async -> NWEndpoint? {
        await withCheckedContinuation { continuation in
            let box = RSSValueContinuationBox<NWEndpoint?>(continuation: continuation)
            let browser = NWBrowser(
                for: .bonjour(type: RSSSummarizeGatewayConfig.bonjourServiceType, domain: nil),
                using: .tcp
            )

            browser.browseResultsChangedHandler = { results, _ in
                if let endpoint = results.first?.endpoint {
                    browser.cancel()
                    box.resume(returning: endpoint)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state {
                    browser.cancel()
                    box.resume(returning: nil)
                }
            }
            browser.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                box.resume(returning: nil)
            }
        }
    }

    private func send(request: RSSSummarizeBridgeRequest, endpoint: NWEndpoint) async throws -> RSSSummarizeBridgeResponse {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let box = RSSBridgeContinuationBox<RSSSummarizeBridgeResponse>(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    do {
                        var payload = try JSONEncoder().encode(request)
                        payload.append(0x0A)
                        connection.send(content: payload, completion: .contentProcessed { error in
                            if let error {
                                box.resume(throwing: error)
                            } else {
                                self.receiveResponse(from: connection, buffer: Data(), box: box)
                            }
                        })
                    } catch {
                        box.resume(throwing: error)
                    }
                case .failed(let error), .waiting(let error):
                    box.resume(throwing: error)
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private func receiveResponse(
        from connection: NWConnection,
        buffer: Data,
        box: RSSBridgeContinuationBox<RSSSummarizeBridgeResponse>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                box.resume(throwing: error)
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let newline = nextBuffer.firstIndex(of: 0x0A) {
                let line = nextBuffer.prefix(upTo: newline)
                do {
                    let response = try JSONDecoder().decode(RSSSummarizeBridgeResponse.self, from: Data(line))
                    box.resume(returning: response)
                } catch {
                    box.resume(throwing: error)
                }
                return
            }

            if isComplete {
                do {
                    let response = try JSONDecoder().decode(RSSSummarizeBridgeResponse.self, from: nextBuffer)
                    box.resume(returning: response)
                } catch {
                    box.resume(throwing: error)
                }
                return
            }

            self.receiveResponse(from: connection, buffer: nextBuffer, box: box)
        }
    }
}

enum RSSSummarizeProviderClient {
    static func ping(settings: AppSettings) async throws -> String {
        #if os(iOS)
        if !AppSettings.sanitizedSummarizeSecret(settings.summarizeBridgeSecret).isEmpty {
            return try await RSSSummarizeBridgeClient(configuration: bridgeConfiguration(from: settings)).ping()
        }
        #endif

        return try await RSSSummarizeDaemonHTTPClient(configuration: daemonConfiguration(from: settings)).ping()
    }

    static func generate(
        prompt: String,
        settings: AppSettings,
        onPartial: ((String) -> Void)? = nil
    ) async throws -> String {
        #if os(iOS)
        if !AppSettings.sanitizedSummarizeSecret(settings.summarizeBridgeSecret).isEmpty {
            return try await RSSSummarizeBridgeClient(configuration: bridgeConfiguration(from: settings))
                .generate(prompt: prompt, onPartial: onPartial)
        }
        #endif

        return try await RSSSummarizeDaemonHTTPClient(configuration: daemonConfiguration(from: settings))
            .generate(prompt: prompt, onPartial: onPartial)
    }

    static func daemonConfiguration(from settings: AppSettings) throws -> RSSSummarizeDaemonConfiguration {
        let port = AppSettings.sanitizedSummarizePort(settings.summarizeDaemonPort, fallback: 8787)
        guard (1...65_535).contains(port) else { throw RSSSummarizeProviderError.invalidPort(port) }

        let preferred = RSSSummarizeDaemonTokenResolver.sanitized(settings.summarizeDaemonToken)
        let fallback = RSSSummarizeKeychain.string(for: RSSSummarizeKeychain.daemonTokenKey)
        let token = RSSSummarizeDaemonTokenResolver.effectiveToken(preferred: preferred, fallback: fallback)
        guard !token.isEmpty else { throw RSSSummarizeProviderError.missingDaemonToken }

        return RSSSummarizeDaemonConfiguration(
            host: AppSettings.sanitizedSummarizeHost(settings.summarizeDaemonHost),
            port: port,
            token: token,
            model: AppSettings.normalizedSummarizeDaemonModel(settings.summarizeDaemonModel)
        )
    }

    static func bridgeConfiguration(from settings: AppSettings) throws -> RSSSummarizeBridgeConfiguration {
        let port = AppSettings.sanitizedSummarizePort(settings.summarizeBridgePort, fallback: AppSettings.defaultSummarizeBridgePort)
        guard (1...65_535).contains(port) else { throw RSSSummarizeProviderError.invalidPort(port) }

        let secret = AppSettings.sanitizedSummarizeSecret(settings.summarizeBridgeSecret)
        guard !secret.isEmpty else { throw RSSSummarizeProviderError.missingBridgeSecret }

        return RSSSummarizeBridgeConfiguration(
            host: settings.summarizeBridgeHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            secret: secret
        )
    }
}

#if os(macOS)
final class RSSSummarizeBridgeServer: @unchecked Sendable {
    static let shared = RSSSummarizeBridgeServer()

    private let queue = DispatchQueue(label: "RSSReaderApp.summarize.bridge.server")
    private var listener: NWListener?
    private var currentPort: Int?
    private var currentSettings = AppSettings()

    private init() {}

    func reconfigure(settings: AppSettings) {
        queue.async {
            var normalized = settings
            normalized.summarizeBridgeSecret = AppSettings.sanitizedSummarizeSecret(settings.summarizeBridgeSecret)
            normalized.summarizeDaemonToken = AppSettings.sanitizedSummarizeSecret(settings.summarizeDaemonToken)
            normalized.summarizeDaemonModel = AppSettings.normalizedSummarizeDaemonModel(settings.summarizeDaemonModel)
            normalized.summarizeBridgePort = AppSettings.sanitizedSummarizePort(settings.summarizeBridgePort, fallback: AppSettings.defaultSummarizeBridgePort)
            normalized.summarizeDaemonPort = AppSettings.sanitizedSummarizePort(settings.summarizeDaemonPort, fallback: 8787)
            self.currentSettings = normalized

            guard self.currentPort != normalized.summarizeBridgePort || self.listener == nil else { return }
            self.stopLocked()
            self.startLocked(port: normalized.summarizeBridgePort)
        }
    }

    private func startLocked(port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = NWListener.Service(
                name: "RSSReaderApp",
                type: RSSSummarizeGatewayConfig.bonjourServiceType
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("Summarize bridge listener failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            self.currentPort = port
            print("Summarize bridge listening on port \(port)")
        } catch {
            print("Failed to start Summarize bridge on port \(port): \(error.localizedDescription)")
        }
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        currentPort = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(from: connection, buffer: Data())
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            if let error {
                self.send(response: .init(ok: false, text: nil, error: error.localizedDescription), to: connection)
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let newline = nextBuffer.firstIndex(of: 0x0A) {
                let line = nextBuffer.prefix(upTo: newline)
                self.handleRequestData(Data(line), connection: connection)
                return
            }

            if isComplete {
                self.handleRequestData(nextBuffer, connection: connection)
                return
            }

            self.receiveRequest(from: connection, buffer: nextBuffer)
        }
    }

    private func handleRequestData(_ data: Data, connection: NWConnection) {
        do {
            let request = try JSONDecoder().decode(RSSSummarizeBridgeRequest.self, from: data)
            let expectedSecret = currentBridgeSecret()
            guard !expectedSecret.isEmpty, request.secret == expectedSecret else {
                send(response: .init(ok: false, text: nil, error: "Summarize bridge secret/pass is incorrect."), to: connection)
                return
            }

            let settings = currentSettings
            Task {
                do {
                    let text: String
                    switch request.kind {
                    case .ping:
                        _ = try await RSSSummarizeProviderClient.ping(settings: settings)
                        text = "Mac bridge connected. Summarize daemon connected."
                    case .generate:
                        guard let prompt = request.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw RSSSummarizeProviderError.emptyResponse
                        }
                        text = try await RSSSummarizeProviderClient.generate(prompt: prompt, settings: settings)
                    }
                    self.send(response: .init(ok: true, text: text, error: nil), to: connection)
                } catch {
                    self.send(response: .init(ok: false, text: nil, error: error.localizedDescription), to: connection)
                }
            }
        } catch {
            send(response: .init(ok: false, text: nil, error: error.localizedDescription), to: connection)
        }
    }

    private func currentBridgeSecret() -> String {
        let settingsSecret = AppSettings.sanitizedSummarizeSecret(currentSettings.summarizeBridgeSecret)
        if !settingsSecret.isEmpty { return settingsSecret }
        return AppSettings.sanitizedSummarizeSecret(UserDefaults.standard.string(forKey: "macBridgeSecret") ?? "")
    }

    private func send(response: RSSSummarizeBridgeResponse, to connection: NWConnection) {
        do {
            var data = try JSONEncoder().encode(response)
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }
}
#endif
