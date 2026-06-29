import Foundation
import Darwin
import LocalAuthentication
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
    case fmNotFound
    case processFailed(Int32, String)
    case terminalAutomationFailed(String)
    case emptyResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .fmNotFound:
            return "Apple PCC is unavailable on this Mac."
        case .processFailed(_, let output):
            if output.localizedCaseInsensitiveContains("PCC inference is not available") {
                return "Apple PCC is unavailable: \(output)"
            }
            if output.localizedCaseInsensitiveContains("quota") || output.localizedCaseInsensitiveContains("rate limit") {
                return "Apple PCC quota is exhausted or rate-limited: \(output)"
            }
            return output.isEmpty ? "Apple PCC failed without an error message." : "Apple PCC failed: \(output)"
        case .terminalAutomationFailed(let output):
            return "Apple PCC needs to run through Terminal on this beta. Terminal automation failed: \(output)"
        case .emptyResponse:
            return "Apple PCC returned an empty response."
        case .cancelled:
            return "Apple PCC request was cancelled."
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

    private static func nonInteractiveAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

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
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: nonInteractiveAuthenticationContext()
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
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: nonInteractiveAuthenticationContext()
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
            attributes.removeValue(forKey: kSecUseAuthenticationContext as String)
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
    private static let fmURL = URL(fileURLWithPath: "/usr/bin/fm")
    private static let ansiPattern = "\u{001B}\\[[0-9;]*m"
    private static let helperDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".aiassistant-pcc-helper", isDirectory: true)

    private let processQueue = DispatchQueue(label: "com.joaovalente.RSSReaderApp.FMPCC.process")
    private var currentProcess: Process?
    private var currentTerminalShellPID: Int32?

    init(configuration: FMPCCGatewayConfiguration? = nil) {}

    func health() async throws -> String {
        try await Self.availabilityDescription()
    }

    static func availabilityDescription() async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: fmURL.path) else {
            throw FMPCCGatewayError.fmNotFound
        }

        let result = try await runProcess(executableURL: fmURL, arguments: ["available", "--model", "pcc"])
        if result.status == 0 {
            let output = stripANSI(result.output)
            return output.isEmpty ? "PCC model available." : output
        }

        let directOutput = stripANSI(result.output)
        if isPCCContextUnavailable(directOutput) {
            let terminalResult = try await runOneShotViaTerminal(arguments: ["available", "--model", "pcc"])
            if terminalResult.status == 0 {
                let terminalOutput = stripANSI(terminalResult.output)
                return terminalOutput.isEmpty ? "PCC model available via Terminal." : "\(terminalOutput) (via Terminal)"
            }
            let terminalOutput = stripANSI(terminalResult.output)
            throw FMPCCGatewayError.processFailed(terminalResult.status, terminalOutput.isEmpty ? directOutput : terminalOutput)
        }

        throw FMPCCGatewayError.processFailed(result.status, directOutput)
    }

    func generate(prompt: String) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.fmURL.path) else {
            throw FMPCCGatewayError.fmNotFound
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw FMPCCGatewayError.emptyResponse }

        let arguments = ["respond", "--model", "pcc", "--no-stream", "--text", trimmedPrompt]
        let result = try await withTaskCancellationHandler {
            let directResult = try await runFM(arguments: arguments)
            if directResult.status != 0, Self.isPCCContextUnavailable(directResult.output) {
                return try await runFMViaTerminalHelper(arguments: arguments)
            }
            return directResult
        } onCancel: {
            self.cancel()
        }

        if Task.isCancelled {
            throw FMPCCGatewayError.cancelled
        }
        guard result.status == 0 else {
            throw FMPCCGatewayError.processFailed(result.status, result.output)
        }

        let output = Self.cleanFMResponse(result.output)
        guard !output.isEmpty else { throw FMPCCGatewayError.emptyResponse }
        return output
    }

    func cancel() {
        let process = processQueue.sync {
            let process = currentProcess
            currentProcess = nil
            return process
        }
        if let process, process.isRunning {
            process.terminate()
        }

        let terminalShellPID = processQueue.sync {
            let pid = currentTerminalShellPID
            currentTerminalShellPID = nil
            return pid
        }
        if let terminalShellPID {
            Self.terminateTerminalJob(shellPID: terminalShellPID)
        }
    }

    private func runFM(arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.fmURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let outputBuffer = LockedProcessOutput()
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }

        setCurrentProcess(process)
        do {
            try process.run()
        } catch {
            fileHandle.readabilityHandler = nil
            clearCurrentProcess(process)
            throw FMPCCGatewayError.fmNotFound
        }

        let status = await withCheckedContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
        }

        fileHandle.readabilityHandler = nil
        outputBuffer.append(fileHandle.readDataToEndOfFile())
        let output = outputBuffer.stringValue()
        clearCurrentProcess(process)
        return (status, Self.stripANSI(output))
    }

    private func setCurrentProcess(_ process: Process?) {
        processQueue.sync {
            currentProcess = process
        }
    }

    private func clearCurrentProcess(_ process: Process) {
        processQueue.sync {
            if currentProcess === process {
                currentProcess = nil
            }
        }
    }

    private func setCurrentTerminalShellPID(_ pid: Int32?) {
        processQueue.sync {
            currentTerminalShellPID = pid
        }
    }

    private func runFMViaTerminalHelper(arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Self.ensureTerminalHelperStarted()

        let jobDirectory = Self.helperDirectory
            .appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }

        let scriptURL = jobDirectory.appendingPathComponent("run.zsh")
        let readyURL = jobDirectory.appendingPathComponent("request.ready")
        let outputURL = jobDirectory.appendingPathComponent("output.txt")
        let statusURL = jobDirectory.appendingPathComponent("status.txt")
        let pidURL = jobDirectory.appendingPathComponent("pid.txt")
        let doneURL = jobDirectory.appendingPathComponent("done")

        let command = ([Self.fmURL.path] + arguments).map(Self.shellDisplayArgument).joined(separator: " ")
        let script = """
        #!/bin/zsh
        echo $$ > \(Self.shellDisplayArgument(pidURL.path))
        \(command) > \(Self.shellDisplayArgument(outputURL.path)) 2>&1
        fm_status=$?
        echo $fm_status > \(Self.shellDisplayArgument(statusURL.path))
        touch \(Self.shellDisplayArgument(doneURL.path))
        exit $fm_status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        try Data().write(to: readyURL, options: .atomic)

        for _ in 0..<1200 {
            if FileManager.default.fileExists(atPath: doneURL.path) {
                break
            }
            if let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
               let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                setCurrentTerminalShellPID(pid)
            }
            if Task.isCancelled {
                cancel()
                throw FMPCCGatewayError.cancelled
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        setCurrentTerminalShellPID(nil)

        guard FileManager.default.fileExists(atPath: doneURL.path) else {
            throw FMPCCGatewayError.processFailed(1, "Timed out waiting for Terminal to finish the Apple PCC request.")
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let statusText = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "1"
        let fmStatus = Int32(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return (fmStatus, Self.stripANSI(output))
    }

    private static func ensureTerminalHelperStarted() async throws {
        try FileManager.default.createDirectory(
            at: helperDirectory.appendingPathComponent("jobs", isDirectory: true),
            withIntermediateDirectories: true
        )

        let pidURL = helperDirectory.appendingPathComponent("helper.pid")
        if let pid = readPID(from: pidURL), isProcessRunning(pid: pid) {
            return
        }

        try? FileManager.default.removeItem(at: pidURL)
        let helperScriptURL = helperDirectory.appendingPathComponent("helper.zsh")
        let jobsPath = helperDirectory.appendingPathComponent("jobs", isDirectory: true).path
        let helperScript = """
        #!/bin/zsh
        setopt NULL_GLOB
        echo $$ > \(shellDisplayArgument(pidURL.path))
        echo -ne "\\033]0;Aiassistant PCC Helper\\007"
        jobs_dir=\(shellDisplayArgument(jobsPath))
        mkdir -p "$jobs_dir"
        while true; do
          for job_dir in "$jobs_dir"/*; do
            [ -d "$job_dir" ] || continue
            [ -f "$job_dir/request.ready" ] || continue
            [ ! -f "$job_dir/started" ] || continue
            touch "$job_dir/started"
            /bin/zsh "$job_dir/run.zsh" > "$job_dir/helper.log" 2>&1
            touch "$job_dir/done"
          done
          sleep 0.2
        done
        """
        try helperScript.write(to: helperScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperScriptURL.path)

        let appleScript = """
        on run argv
            tell application "Terminal"
                do script "/bin/zsh " & quoted form of item 1 of argv
                delay 0.2
                try
                    set miniaturized of front window to true
                end try
            end tell
        end run
        """
        let launchResult = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript, helperScriptURL.path]
        )
        guard launchResult.status == 0 else {
            throw FMPCCGatewayError.terminalAutomationFailed(stripANSI(launchResult.output))
        }

        for _ in 0..<40 {
            if let pid = readPID(from: pidURL), isProcessRunning(pid: pid) {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FMPCCGatewayError.terminalAutomationFailed("Timed out waiting for the persistent PCC helper to start.")
    }

    private static func runOneShotViaTerminal(arguments: [String]) async throws -> (status: Int32, output: String) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RSSReader-FMPCC-Availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let scriptURL = tempDirectory.appendingPathComponent("check-fm-pcc.zsh")
        let outputURL = tempDirectory.appendingPathComponent("output.txt")
        let statusURL = tempDirectory.appendingPathComponent("status.txt")
        let doneURL = tempDirectory.appendingPathComponent("done")

        let command = ([fmURL.path] + arguments).map(shellDisplayArgument).joined(separator: " ")
        let script = """
        #!/bin/zsh
        \(command) > \(shellDisplayArgument(outputURL.path)) 2>&1
        fm_status=$?
        echo $fm_status > \(shellDisplayArgument(statusURL.path))
        touch \(shellDisplayArgument(doneURL.path))
        exit $fm_status
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let appleScript = """
        on run argv
            tell application "Terminal"
                do script "/bin/zsh " & quoted form of item 1 of argv
            end tell
        end run
        """
        let launchResult = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript, scriptURL.path]
        )
        guard launchResult.status == 0 else {
            throw FMPCCGatewayError.terminalAutomationFailed(stripANSI(launchResult.output))
        }

        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: doneURL.path) {
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let statusText = (try? String(contentsOf: statusURL, encoding: .utf8)) ?? "1"
                let fmStatus = Int32(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                return (fmStatus, stripANSI(output))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return (1, "Timed out waiting for Terminal to check PCC availability.")
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ansiPattern) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPCCContextUnavailable(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("PCC inference is not available in this context")
    }

    private static func cleanFMResponse(_ output: String) -> String {
        output
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Session saved:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func terminateTerminalJob(shellPID: Int32) {
        let shellPIDText = String(shellPID)
        _ = try? runDetachedProcess(executableURL: URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-TERM", "-P", shellPIDText])
        _ = try? runDetachedProcess(executableURL: URL(fileURLWithPath: "/bin/kill"), arguments: ["-TERM", shellPIDText])
    }

    private static func runDetachedProcess(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
    }

    private static func readPID(from url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["-0", String(pid)]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func shellDisplayArgument(_ argument: String) -> String {
        if argument.contains(" ") || argument.contains("\n") || argument.contains("'") || argument.contains("\"") {
            return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
        return argument
    }
}

private final class LockedProcessOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.joaovalente.RSSReaderApp.FMPCC.output")
    private var data = Data()

    func append(_ newData: Data) {
        queue.sync {
            data.append(newData)
        }
    }

    func stringValue() -> String {
        queue.sync {
            String(data: data, encoding: .utf8) ?? ""
        }
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
            host: AppSettings.sanitizedSummarizeHost(settings.summarizeBridgeHost),
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
