//
//  ChatGPTPlanService.swift
//  RSSReaderApp
//
//  "Sign in with ChatGPT" plan usage: AI requests run on the user's own
//  ChatGPT Plus/Pro plan. OpenAI currently allows this for personal apps that
//  run locally, so the provider is only offered in development-signed installs
//  (see ChatGPTPlanAvailability). TestFlight and App Store builds never show it.
//
//  Flow (mirrors OpenAI's open-source SIWC devkit):
//  OAuth + PKCE against auth.openai.com with a loopback callback on 127.0.0.1,
//  then streamed POST https://api.openai.com/v1/responses with store:false.
//

import Foundation
import Network
import AuthenticationServices
import CryptoKit
import Security
import Combine
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Local-only gate

nonisolated enum ChatGPTPlanAvailability {
    /// True for Simulator runs and for iPhone/iPad installs signed with a development
    /// profile (Xcode Run, Debug or Release). Archives exported for TestFlight or the
    /// App Store are distribution-signed, so the provider stays hidden there. The Mac
    /// (Catalyst) build never offers it.
    static let isEnabled: Bool = {
        #if targetEnvironment(macCatalyst)
        return false
        #elseif targetEnvironment(simulator)
        return true
        #elseif os(iOS)
        return provisioningProfileAllowsDebugging()
        #else
        return false
        #endif
    }()

    #if os(iOS)
    private static func provisioningProfileAllowsDebugging() -> Bool {
        // App Store and TestFlight installs carry no embedded profile.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return false
        }
        // The profile is a signed CMS envelope with the plist stored as plain XML.
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return false
        }
        return entitlements["get-task-allow"] as? Bool == true
    }
    #endif
}

// MARK: - Types

nonisolated struct ChatGPTPlanError: LocalizedError {
    let code: String
    let message: String
    var param: String? = nil
    var status: Int? = nil

    var errorDescription: String? { message }

    static let usageLimitCode = "subscription_sharing_usage_limit_exceeded"

    var isCancellation: Bool { code == "cancelled" }

    /// The route rejected a request field for every model.
    func rejectsParameter(_ name: String) -> Bool {
        guard status == 400, names(name), !isModelSpecific else { return false }
        let lowered = message.lowercased()
        return code == "unsupported_parameter"
            || code == "unknown_parameter"
            || lowered.contains("unsupported parameter")
            || lowered.contains("unknown parameter")
            || lowered.contains("not supported")
    }

    /// The route accepts the field, but not this value or not for this model.
    func rejectsValue(of name: String) -> Bool {
        guard status == 400, names(name) else { return false }
        return isModelSpecific
            || code == "unsupported_value"
            || message.lowercased().contains("unsupported value")
    }

    private var isModelSpecific: Bool {
        message.lowercased().contains("this model")
    }

    private func names(_ parameter: String) -> Bool {
        (param ?? "").lowercased().hasPrefix(parameter) || message.lowercased().contains(parameter)
    }
}

nonisolated struct ChatGPTPlanModel: Codable, Hashable, Identifiable {
    let slug: String
    let displayName: String
    /// Reasoning efforts the catalog lists for this model; empty when it lists none.
    let reasoningEfforts: [String]
    let defaultReasoningEffort: String?
    /// The catalog's Fast speed tier for this model (service_tier id, e.g. "priority").
    var fastTierID: String? = nil
    var fastTierDescription: String? = nil

    var id: String { slug }
}

nonisolated enum ChatGPTPlanCapability: String, Codable {
    case unknown
    case supported
    case unsupported
}

nonisolated struct ChatGPTPlanRequestOptions {
    var model: String
    var reasoningEffort: String?
    /// Sent as service_tier; nil runs at normal speed.
    var serviceTier: String?
}

nonisolated private struct ChatGPTPlanConnection: Codable {
    var clientID: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scopes: [String]
    var subject: String
    var email: String?
    var name: String?
}

nonisolated private struct ChatGPTPlanDiscovery: Decodable {
    let issuer: String
    let authorization_endpoint: String
    let token_endpoint: String
    let revocation_endpoint: String?
}

nonisolated struct ChatGPTLoopbackCallback: Sendable {
    let code: String?
    let clientID: String?
    let error: String?
    let errorDescription: String?
}

// MARK: - Service

@MainActor
final class ChatGPTPlanService: NSObject, ObservableObject {
    static let shared = ChatGPTPlanService()

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reauthRequired
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountName: String?
    @Published private(set) var planUsageGranted = false
    @Published private(set) var models: [ChatGPTPlanModel] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var reasoningSupport: ChatGPTPlanCapability
    @Published private(set) var fastSupport: ChatGPTPlanCapability
    /// Models where OpenAI accepted Fast but reported running the default tier.
    @Published private(set) var fastIgnoredModels: Set<String>
    /// Models the user entered by name; shown in the picker after the catalog.
    @Published private(set) var customModels: [String]
    @Published var lastError: String?

    /// Chosen model slug; empty uses the first model in the account's catalog.
    @Published private(set) var selectedModel: String
    /// Empty means the model's default reasoning effort.
    @Published var reasoningEffort: String {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: Self.reasoningEffortDefaultsKey) }
    }
    @Published var fastMode: Bool {
        didSet { UserDefaults.standard.set(fastMode, forKey: Self.fastModeDefaultsKey) }
    }

    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let fallbackReasoningEfforts = ["low", "medium", "high"]

    private static let issuer = "https://auth.openai.com"
    private static let resource = "https://api.openai.com/v1"
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    private static let planScope = "chatgpt.tokens.use.direct"
    private static let initialClientID = "dynamic_agent_client"
    private static let preferredCallbackPort: UInt16 = 1455
    nonisolated private static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    nonisolated private static let modelsURL = URL(string: "https://api.openai.com/v1/models")!

    private static let connectionAccount = "connection"
    private static let clientIDAccount = "client_id"
    private static let modelsDefaultsKey = "chatGPTPlan.models"
    // v2: the first build marked Fast unsupported from the response echo alone.
    private static let reasoningSupportDefaultsKey = "chatGPTPlan.reasoningSupport.v2"
    private static let fastSupportDefaultsKey = "chatGPTPlan.fastSupport.v2"
    /// Codex release that introduced GPT-6.1 Sol. The catalog lists a model only
    /// for clients at or above its minimal_client_version.
    nonisolated private static let catalogClientVersion = "0.159.1"
    private static let lastEmailDefaultsKey = "chatGPTPlan.lastEmail"
    private static let fastIgnoredDefaultsKey = "chatGPTPlan.fastIgnoredModels"
    /// The service_tier value Check Connection found OpenAI honors ("fast" or the
    /// older "priority"); nil uses the catalog's tier id.
    private static let fastWireValueDefaultsKey = "chatGPTPlan.fastWireValue"
    /// Tier names that mean the request ran on the Fast tier.
    nonisolated private static let fastTierNames: Set<String> = ["fast", "priority"]
    private static let customModelsDefaultsKey = "chatGPTPlan.customModels"
    private static let selectedModelDefaultsKey = "chatGPTPlan.selectedModel"
    private static let reasoningEffortDefaultsKey = "chatGPTPlan.reasoningEffort"
    private static let fastModeDefaultsKey = "chatGPTPlan.fastMode"

    nonisolated private static let httpSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Time between bytes; reasoning models can think for a while before the first delta.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1800
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Sign-in, token and model-list calls are small; fail them quickly instead
    /// of waiting through the long streaming timeout.
    nonisolated private static let controlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private var connection: ChatGPTPlanConnection?
    private var refreshTask: Task<ChatGPTPlanConnection, Error>?
    private var cachedDiscovery: ChatGPTPlanDiscovery?
    private var authSession: ASWebAuthenticationSession?

    private override init() {
        let defaults = UserDefaults.standard
        reasoningSupport = defaults.string(forKey: Self.reasoningSupportDefaultsKey)
            .flatMap(ChatGPTPlanCapability.init(rawValue:)) ?? .unknown
        fastSupport = defaults.string(forKey: Self.fastSupportDefaultsKey)
            .flatMap(ChatGPTPlanCapability.init(rawValue:)) ?? .unknown
        fastIgnoredModels = Set(defaults.stringArray(forKey: Self.fastIgnoredDefaultsKey) ?? [])
        customModels = defaults.stringArray(forKey: Self.customModelsDefaultsKey) ?? []
        selectedModel = defaults.string(forKey: Self.selectedModelDefaultsKey) ?? ""
        reasoningEffort = defaults.string(forKey: Self.reasoningEffortDefaultsKey) ?? ""
        fastMode = defaults.bool(forKey: Self.fastModeDefaultsKey)
        if let data = defaults.data(forKey: Self.modelsDefaultsKey),
           let cached = try? JSONDecoder().decode([ChatGPTPlanModel].self, from: data) {
            models = cached
        }
        super.init()

        if let data = ChatGPTPlanKeychain.data(for: Self.connectionAccount),
           let stored = try? JSONDecoder().decode(ChatGPTPlanConnection.self, from: data) {
            apply(stored)
        }
    }

    var isConnected: Bool { status == .connected }

    var accountLabel: String? { accountEmail ?? accountName }

    /// The model requests use: the saved choice, or the catalog's first model.
    var effectiveModel: String {
        selectedModel.isEmpty ? (models.first?.slug ?? "") : selectedModel
    }

    func selectModel(_ slug: String) {
        selectedModel = slug
        UserDefaults.standard.set(slug, forKey: Self.selectedModelDefaultsKey)
        // Keep the effort only if the new model offers it.
        if !reasoningEffort.isEmpty, !reasoningEfforts(forModel: slug).contains(reasoningEffort) {
            reasoningEffort = ""
        }
    }

    func reasoningEfforts(forModel slug: String) -> [String] {
        let listed = models.first { $0.slug == slug }?.reasoningEfforts ?? []
        return listed.isEmpty ? Self.fallbackReasoningEfforts : listed
    }

    func defaultReasoningEffort(forModel slug: String) -> String? {
        models.first { $0.slug == slug }?.defaultReasoningEffort
    }

    /// The Fast tier for a model: from the catalog when the model is listed,
    /// otherwise the standard "priority" tier for a model entered by name.
    func fastTier(forModel slug: String) -> (id: String, description: String?)? {
        guard let tier = catalogFastTier(forModel: slug) else { return nil }
        let learned = UserDefaults.standard.string(forKey: Self.fastWireValueDefaultsKey)
        return (learned ?? tier.id, tier.description)
    }

    private func catalogFastTier(forModel slug: String) -> (id: String, description: String?)? {
        guard let model = models.first(where: { $0.slug == slug }) else {
            return slug.isEmpty ? nil : ("priority", nil)
        }
        return model.fastTierID.map { ($0, model.fastTierDescription) }
    }

    // MARK: Sign-in

    func signIn() async {
        guard ChatGPTPlanAvailability.isEnabled, status != .connecting else { return }
        let previousStatus = status
        lastError = nil
        status = .connecting
        do {
            let connected = try await authorize()
            persist(connected)
            apply(connected)
            if !planUsageGranted {
                lastError = "Signed in, but ChatGPT did not grant plan usage. It requires an eligible Plus or Pro plan."
            }
            await refreshModels()
        } catch let error as ChatGPTPlanError where error.isCancellation {
            status = previousStatus == .connecting ? .disconnected : previousStatus
        } catch {
            status = previousStatus == .connecting ? .disconnected : previousStatus
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        let current = connection
        authSession?.cancel()
        authSession = nil
        refreshTask = nil
        connection = nil
        ChatGPTPlanKeychain.delete(Self.connectionAccount)
        status = .disconnected
        planUsageGranted = false
        accountName = nil
        accountEmail = nil
        lastError = nil

        // Revoking the refresh token ends the renewable session on OpenAI's side.
        // The registered client ID is kept so a later sign-in reuses it.
        guard let current else { return }
        do {
            let discovery = try await discovery()
            guard let revocationEndpoint = discovery.revocation_endpoint else { return }
            _ = try await Self.formRequest(endpoint: revocationEndpoint, fields: [
                ("token", current.refreshToken),
                ("token_type_hint", "refresh_token"),
                ("client_id", current.clientID)
            ], expectsJSON: false)
        } catch {
            lastError = "Signed out here, but OpenAI did not confirm the disconnect. You can remove RSSum in ChatGPT settings."
        }
    }

    private func authorize() async throws -> ChatGPTPlanConnection {
        let provider = try await discovery()
        let state = Self.randomValue()
        let nonce = Self.randomValue()
        let verifier = Self.randomValue()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        let listener = ChatGPTLoopbackListener(expectedState: state)
        let port = try await listener.start(preferredPort: Self.preferredCallbackPort)
        defer { listener.stop() }
        let redirectURI = "http://127.0.0.1:\(port)/auth/callback"

        let savedClientID = ChatGPTPlanKeychain.string(for: Self.clientIDAccount)
        guard var components = URLComponents(string: provider.authorization_endpoint) else {
            throw ChatGPTPlanError(code: "discovery_failed", message: "ChatGPT sign-in configuration could not be verified.")
        }
        var items = [
            URLQueryItem(name: "client_id", value: savedClientID ?? Self.initialClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        if savedClientID == nil {
            items.append(URLQueryItem(name: "agent_name_hint", value: "RSSum"))
        }
        if let email = connection?.email ?? UserDefaults.standard.string(forKey: Self.lastEmailDefaultsKey) {
            items.append(URLQueryItem(name: "login_hint", value: email))
        }
        components.queryItems = items
        guard let authorizationURL = components.url else {
            throw ChatGPTPlanError(code: "discovery_failed", message: "ChatGPT sign-in configuration could not be verified.")
        }

        let callback = try await runBrowserSession(url: authorizationURL, listener: listener)
        if let error = callback.error {
            let message = error == "access_denied"
                ? "ChatGPT sign-in was declined."
                : (callback.errorDescription ?? "ChatGPT sign-in failed (\(error)).")
            throw ChatGPTPlanError(code: error, message: message)
        }
        let clientID = callback.clientID ?? savedClientID
        guard let code = callback.code,
              let clientID,
              clientID != Self.initialClientID,
              clientID.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil,
              savedClientID == nil || callback.clientID == nil || callback.clientID == savedClientID else {
            throw ChatGPTPlanError(code: "registration_incomplete", message: "ChatGPT did not complete app registration. Please try signing in again.")
        }
        // A one-time code can fail after registration succeeds; keep the issued
        // client ID so the next attempt does not register RSSum again.
        ChatGPTPlanKeychain.set(clientID, for: Self.clientIDAccount)

        let response = try await Self.formRequest(endpoint: provider.token_endpoint, fields: [
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
            ("resource", Self.resource)
        ])
        let tokens = try Self.tokenSet(from: response, fallbackScopes: nil)
        guard let refreshToken = tokens.refreshToken else {
            throw ChatGPTPlanError(code: "invalid_token_response", message: "ChatGPT returned incomplete credentials. Please sign in again.")
        }
        guard let idToken = response["id_token"] as? String else {
            throw ChatGPTPlanError(code: "invalid_id_token", message: "ChatGPT did not return a verifiable identity. Please try signing in again.")
        }
        let identity = try Self.verifyIDToken(idToken, clientID: clientID, nonce: nonce)
        return ChatGPTPlanConnection(
            clientID: clientID,
            accessToken: tokens.accessToken,
            refreshToken: refreshToken,
            expiresAt: tokens.expiresAt,
            scopes: tokens.scopes,
            subject: identity.subject,
            email: identity.email,
            name: identity.name
        )
    }

    private func runBrowserSession(
        url: URL,
        listener: ChatGPTLoopbackListener
    ) async throws -> ChatGPTLoopbackCallback {
        try await withCheckedThrowingContinuation { continuation in
            let once = ChatGPTResumeOnce()
            let finish: @MainActor (Result<ChatGPTLoopbackCallback, Error>) -> Void = { [weak self] result in
                guard once.claim() else { return }
                continuation.resume(with: result)
                // After the loopback page loads, close the sign-in sheet ourselves.
                self?.authSession?.cancel()
                self?.authSession = nil
            }

            // The callback scheme never fires: OpenAI returns to the loopback listener.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "rssum-chatgpt") { _, error in
                Task { @MainActor in
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    finish(.failure(cancelled || error == nil
                        ? ChatGPTPlanError(code: "cancelled", message: "Sign-in was cancelled.")
                        : ChatGPTPlanError(code: "browser_failed", message: error?.localizedDescription ?? "Sign-in failed.")))
                }
            }
            listener.setOnCallback { callback in
                Task { @MainActor in finish(.success(callback)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            if !session.start() {
                finish(.failure(ChatGPTPlanError(code: "browser_failed", message: "The ChatGPT sign-in window could not be opened.")))
            }
        }
    }

    // MARK: Tokens

    private func apply(_ stored: ChatGPTPlanConnection) {
        connection = stored
        accountEmail = stored.email
        accountName = stored.name
        planUsageGranted = stored.scopes.contains(Self.planScope)
        status = .connected
        if let email = stored.email {
            UserDefaults.standard.set(email, forKey: Self.lastEmailDefaultsKey)
        }
    }

    private func persist(_ stored: ChatGPTPlanConnection) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        ChatGPTPlanKeychain.set(data, for: Self.connectionAccount)
    }

    private func validConnection(forceRefresh: Bool = false) async throws -> ChatGPTPlanConnection {
        guard let current = connection else {
            throw ChatGPTPlanError(
                code: "not_connected",
                message: status == .reauthRequired
                    ? "Your ChatGPT connection expired. Sign in again in Settings → Summary Provider."
                    : "Sign in with ChatGPT in Settings → Summary Provider first."
            )
        }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        // One refresh at a time: refresh tokens rotate, so a second concurrent
        // refresh with the old token would fail.
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            persist(refreshed)
            apply(refreshed)
            return refreshed
        } catch let error as ChatGPTPlanError where error.code == "invalid_grant" || error.code == "account_mismatch" {
            connection = nil
            ChatGPTPlanKeychain.delete(Self.connectionAccount)
            status = .reauthRequired
            throw ChatGPTPlanError(code: error.code, message: "Your ChatGPT connection expired. Sign in again in Settings → Summary Provider.")
        }
    }

    private func performRefresh(_ previous: ChatGPTPlanConnection) async throws -> ChatGPTPlanConnection {
        let provider = try await discovery()
        let response = try await Self.formRequest(endpoint: provider.token_endpoint, fields: [
            ("grant_type", "refresh_token"),
            ("client_id", previous.clientID),
            ("refresh_token", previous.refreshToken),
            ("resource", Self.resource)
        ])
        // OAuth may omit scope on refresh when the granted scopes are unchanged.
        let tokens = try Self.tokenSet(from: response, fallbackScopes: previous.scopes)
        var refreshed = previous
        refreshed.accessToken = tokens.accessToken
        refreshed.refreshToken = tokens.refreshToken ?? previous.refreshToken
        refreshed.expiresAt = tokens.expiresAt
        refreshed.scopes = tokens.scopes
        if let idToken = response["id_token"] as? String {
            let identity = try Self.verifyIDToken(idToken, clientID: previous.clientID, nonce: nil)
            guard identity.subject == previous.subject else {
                throw ChatGPTPlanError(code: "account_mismatch", message: "The refreshed ChatGPT account does not match. Sign in again.")
            }
            refreshed.email = identity.email ?? previous.email
            refreshed.name = identity.name ?? previous.name
        }
        return refreshed
    }

    private func discovery() async throws -> ChatGPTPlanDiscovery {
        if let cachedDiscovery { return cachedDiscovery }
        let url = URL(string: "\(Self.issuer)/.well-known/openid-configuration")!
        let (data, response) = try await Self.controlSession.data(from: url)
        let endpointsStayOnIssuer: (ChatGPTPlanDiscovery) -> Bool = { discovery in
            [discovery.authorization_endpoint, discovery.token_endpoint]
                .allSatisfy { URL(string: $0)?.host == "auth.openai.com" && URL(string: $0)?.scheme == "https" }
                && (discovery.revocation_endpoint.map { URL(string: $0)?.host == "auth.openai.com" } ?? true)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let discovery = try? JSONDecoder().decode(ChatGPTPlanDiscovery.self, from: data),
              discovery.issuer == Self.issuer,
              endpointsStayOnIssuer(discovery) else {
            throw ChatGPTPlanError(code: "discovery_failed", message: "ChatGPT sign-in configuration could not be verified.")
        }
        cachedDiscovery = discovery
        return discovery
    }

    private struct TokenSet {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
        let scopes: [String]
    }

    private static func tokenSet(from response: [String: Any], fallbackScopes: [String]?) throws -> TokenSet {
        guard let scopes = (response["scope"] as? String).map({ $0.split(separator: " ").map(String.init) }) ?? fallbackScopes else {
            throw ChatGPTPlanError(code: "invalid_token_response", message: "ChatGPT did not confirm the granted permissions. Please sign in again.")
        }
        guard let accessToken = response["access_token"] as? String, !accessToken.isEmpty,
              (response["token_type"] as? String)?.lowercased() == "bearer",
              let expiresIn = (response["expires_in"] as? NSNumber)?.doubleValue, expiresIn > 0 else {
            throw ChatGPTPlanError(code: "invalid_token_response", message: "ChatGPT returned incomplete credentials. Please sign in again.")
        }
        let refreshToken = (response["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scopes: scopes
        )
    }

    /// The ID token arrives directly from the token endpoint over TLS, so its claims
    /// are checked here in place of a signature check (OpenID Connect Core 3.1.3.7).
    private static func verifyIDToken(
        _ token: String,
        clientID: String,
        nonce: String?
    ) throws -> (subject: String, email: String?, name: String?) {
        let invalid = ChatGPTPlanError(code: "invalid_id_token", message: "The ChatGPT identity could not be verified. Please sign in again.")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payloadData = Data(base64URLEncoded: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw invalid
        }
        let audienceMatches: Bool = {
            if let audience = payload["aud"] as? String { return audience == clientID }
            if let audiences = payload["aud"] as? [String] { return audiences.contains(clientID) }
            return false
        }()
        guard payload["iss"] as? String == issuer,
              audienceMatches,
              let expiry = (payload["exp"] as? NSNumber)?.doubleValue,
              expiry > Date().timeIntervalSince1970 - 5,
              let subject = payload["sub"] as? String, !subject.isEmpty,
              nonce == nil || payload["nonce"] as? String == nonce else {
            throw invalid
        }
        return (subject, payload["email"] as? String, payload["name"] as? String)
    }

    // MARK: Models

    func refreshModels() async {
        guard connection != nil else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let current = try await validConnection()
            let fetched: [ChatGPTPlanModel]
            do {
                fetched = try await Self.fetchModels(accessToken: current.accessToken)
            } catch let error as ChatGPTPlanError where error.status == 401 {
                let refreshed = try await validConnection(forceRefresh: true)
                fetched = try await Self.fetchModels(accessToken: refreshed.accessToken)
            }
            models = fetched
            if let data = try? JSONEncoder().encode(fetched) {
                UserDefaults.standard.set(data, forKey: Self.modelsDefaultsKey)
            }
            // A saved slug that is not listed is kept, so a model entered by name stays selected.
            if selectedModel.isEmpty, let first = fetched.first {
                selectModel(first.slug)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    nonisolated private static func fetchModels(accessToken: String) async throws -> [ChatGPTPlanModel] {
        var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "client_version", value: catalogClientVersion)]
        do {
            return try await fetchModels(from: components.url!, accessToken: accessToken)
        } catch let error as ChatGPTPlanError where error.status == 400 || error.status == 404 || error.status == 422 {
            return try await fetchModels(from: modelsURL, accessToken: accessToken)
        }
    }

    nonisolated private static func fetchModels(from url: URL, accessToken: String) async throws -> [ChatGPTPlanModel] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await controlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(status) else {
            throw apiError(from: object, status: status, fallback: "ChatGPT models could not be loaded.")
        }
        #if DEBUG
        if let text = String(data: data, encoding: .utf8) {
            print("🤖 [ChatGPTPlan] Model catalog: \(text.prefix(4000))")
        }
        #endif
        writeDiagnostic(data, named: "chatgpt-model-catalog.json")

        if let catalog = object?["models"] as? [[String: Any]] {
            return catalog.compactMap { entry in
                guard entry["visibility"] as? String == "list",
                      let slug = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
                    return nil
                }
                let displayName = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug
                let tiers = entry["service_tiers"] as? [[String: Any]] ?? []
                let fastTier = tiers.first { ($0["name"] as? String)?.lowercased() == "fast" }
                    ?? tiers.first { $0["id"] as? String == "priority" }
                return ChatGPTPlanModel(
                    slug: slug,
                    displayName: displayName,
                    reasoningEfforts: reasoningEfforts(in: entry),
                    defaultReasoningEffort: (entry["default_reasoning_level"] as? String)
                        ?? (entry["default_reasoning_effort"] as? String),
                    fastTierID: fastTier?["id"] as? String,
                    fastTierDescription: fastTier?["description"] as? String
                )
            }
            .sorted { lhs, rhs in
                let priority: (String) -> Int = { slug in
                    (catalog.first { $0["slug"] as? String == slug }?["priority"] as? Int) ?? Int.max
                }
                return priority(lhs.slug) < priority(rhs.slug)
            }
        }
        // Standard API shape, in case the catalog route returns it.
        if let list = object?["data"] as? [[String: Any]] {
            return list.compactMap { entry in
                guard let slug = entry["id"] as? String, !slug.isEmpty else { return nil }
                return ChatGPTPlanModel(slug: slug, displayName: slug, reasoningEfforts: [], defaultReasoningEffort: nil)
            }
        }
        throw ChatGPTPlanError(code: "invalid_model_catalog", message: "ChatGPT returned an unexpected model list. Try again.", status: status)
    }

    nonisolated private static func reasoningEfforts(in entry: [String: Any]) -> [String] {
        for key in ["supported_reasoning_levels", "supported_reasoning_efforts", "reasoning_efforts"] {
            guard let values = entry[key] as? [Any] else { continue }
            let efforts = values.compactMap { value -> String? in
                if let effort = value as? String { return effort }
                if let object = value as? [String: Any] {
                    return (object["effort"] as? String) ?? (object["level"] as? String) ?? (object["id"] as? String)
                }
                return nil
            }
            if !efforts.isEmpty { return efforts }
        }
        return []
    }

    // MARK: Inference

    /// Streams one answer from the user's ChatGPT plan. `onPartial` receives text deltas.
    func generate(
        prompt: String,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> String {
        guard ChatGPTPlanAvailability.isEnabled else {
            throw ChatGPTPlanError(code: "unavailable", message: "ChatGPT plan usage is only available in local development builds.")
        }
        var model = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            if models.isEmpty { await refreshModels() }
            guard let first = models.first?.slug else {
                throw ChatGPTPlanError(code: "no_model", message: "Choose a ChatGPT model in Settings → Summary Provider.")
            }
            model = first
        }
        let effort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = ChatGPTPlanRequestOptions(
            model: model,
            reasoningEffort: effort.isEmpty || reasoningSupport == .unsupported ? nil : effort,
            serviceTier: fastMode && fastSupport != .unsupported ? fastTier(forModel: model)?.id : nil
        )
        let result = try await send(prompt: prompt, options: &options, onPartial: onPartial)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ChatGPTPlanError(code: "empty_response", message: "ChatGPT returned no text. Try again.")
        }
        return text
    }

    /// Sends one request, refreshing an expired token once and dropping fields
    /// the route rejects. Rejections are remembered so the settings hide them.
    private func send(
        prompt: String,
        options: inout ChatGPTPlanRequestOptions,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> ChatGPTStreamResult {
        var didRefresh = false
        for _ in 0..<4 {
            let current = try await validConnection()
            do {
                let result = try await Self.streamResponse(
                    accessToken: current.accessToken,
                    prompt: prompt,
                    options: options,
                    onPartial: onPartial
                )
                recordCapabilities(sent: options, result: result)
                return result
            } catch let error as ChatGPTPlanError {
                if error.status == 401, !didRefresh {
                    didRefresh = true
                    _ = try await validConnection(forceRefresh: true)
                    continue
                }
                if options.reasoningEffort != nil, error.rejectsParameter("reasoning") {
                    setReasoningSupport(.unsupported)
                    options.reasoningEffort = nil
                    continue
                }
                if options.reasoningEffort != nil, error.rejectsValue(of: "reasoning") {
                    options.reasoningEffort = nil
                    continue
                }
                if options.serviceTier != nil, error.rejectsParameter("service_tier") || error.rejectsValue(of: "service_tier") {
                    setFastSupport(.unsupported)
                    options.serviceTier = nil
                    continue
                }
                throw error
            }
        }
        throw ChatGPTPlanError(code: "request_failed", message: "ChatGPT could not complete the request. Try again.")
    }

    private func recordCapabilities(sent options: ChatGPTPlanRequestOptions, result: ChatGPTStreamResult) {
        if options.reasoningEffort != nil {
            setReasoningSupport(.supported)
        }
        // Only an explicit rejection hides Fast. The completed response reports the
        // tier that actually ran; "default" means Fast had no effect for this model.
        if let requested = options.serviceTier {
            setFastSupport(.supported)
            if let ran = result.serviceTier {
                if ran == requested || Self.fastTierNames.contains(ran) {
                    fastIgnoredModels.remove(options.model)
                } else {
                    fastIgnoredModels.insert(options.model)
                }
                UserDefaults.standard.set(Array(fastIgnoredModels), forKey: Self.fastIgnoredDefaultsKey)
            }
        }
    }

    /// Remembers a model entered by name so it stays in the picker.
    func rememberCustomModel(_ slug: String) {
        guard !slug.isEmpty, !models.contains(where: { $0.slug == slug }) else { return }
        customModels.removeAll { $0 == slug }
        customModels.insert(slug, at: 0)
        customModels = Array(customModels.prefix(8))
        UserDefaults.standard.set(customModels, forKey: Self.customModelsDefaultsKey)
    }

    func forgetCustomModel(_ slug: String) {
        customModels.removeAll { $0 == slug }
        UserDefaults.standard.set(customModels, forKey: Self.customModelsDefaultsKey)
    }

    private func setReasoningSupport(_ value: ChatGPTPlanCapability) {
        reasoningSupport = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.reasoningSupportDefaultsKey)
    }

    private func setFastSupport(_ value: ChatGPTPlanCapability) {
        fastSupport = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.fastSupportDefaultsKey)
    }

    /// Sends three tiny requests: plain, with a reasoning effort, and with Fast.
    /// Returns a short summary for Settings and saves the details to
    /// Caches/chatgpt-connection-check.json for troubleshooting.
    func checkConnection() async -> String {
        let model = effectiveModel
        guard !model.isEmpty else { return "Choose a model first." }
        let probe = "Reply with exactly: OK"
        var report: [[String: Any]] = []

        func run(_ name: String, _ options: ChatGPTPlanRequestOptions) async -> Result<ChatGPTStreamResult, Error> {
            var sent = options
            var entry: [String: Any] = [
                "probe": name,
                "model": options.model,
                "reasoning_effort": options.reasoningEffort ?? NSNull(),
                "service_tier": options.serviceTier ?? NSNull()
            ]
            do {
                let result = try await send(prompt: probe, options: &sent, onPartial: nil)
                entry["ok"] = true
                entry["sent_reasoning_effort"] = sent.reasoningEffort ?? NSNull()
                entry["sent_service_tier"] = sent.serviceTier ?? NSNull()
                entry["response_service_tier"] = result.serviceTier ?? NSNull()
                entry["response_reasoning_effort"] = result.reasoningEffort ?? NSNull()
                report.append(entry)
                return .success(result)
            } catch {
                entry["ok"] = false
                if let planError = error as? ChatGPTPlanError {
                    entry["error_code"] = planError.code
                    entry["error_status"] = planError.status ?? NSNull()
                    entry["error_param"] = planError.param ?? NSNull()
                }
                entry["error_message"] = error.localizedDescription
                report.append(entry)
                return .failure(error)
            }
        }

        defer {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                Self.writeDiagnostic(data, named: "chatgpt-connection-check.json")
            }
        }

        if case .failure(let error) = await run("plain", ChatGPTPlanRequestOptions(model: model, reasoningEffort: nil, serviceTier: nil)) {
            return "Failed: \(error.localizedDescription)"
        }

        setReasoningSupport(.unknown)
        let efforts = reasoningEfforts(forModel: model)
        let effort = efforts.contains("low") ? "low" : efforts.first
        let reasoningLabel: String
        switch await run("reasoning", ChatGPTPlanRequestOptions(model: model, reasoningEffort: effort, serviceTier: nil)) {
        case .success:
            if reasoningSupport == .unknown { setReasoningSupport(.supported) }
            reasoningLabel = reasoningSupport == .supported ? "yes" : "not available"
        case .failure(let error):
            reasoningLabel = "failed (\(error.localizedDescription))"
        }

        // OpenAI renamed the "priority" tier to "fast" (July 2026). Try the current
        // name first, then the catalog's id, and keep whichever OpenAI reports running.
        let fastLabel: String
        if let tier = catalogFastTier(forModel: model) {
            var candidates = ["fast"]
            if !candidates.contains(tier.id) { candidates.append(tier.id) }
            var honored: String?
            var accepted = false
            var lastError: Error?
            for value in candidates {
                setFastSupport(.unknown)
                switch await run("fast:\(value)", ChatGPTPlanRequestOptions(model: model, reasoningEffort: nil, serviceTier: value)) {
                case .success(let result):
                    if fastSupport == .supported {
                        accepted = true
                        if let ran = result.serviceTier, Self.fastTierNames.contains(ran) {
                            honored = value
                        }
                    }
                case .failure(let error):
                    lastError = error
                }
                if honored != nil { break }
            }
            if let honored {
                UserDefaults.standard.set(honored, forKey: Self.fastWireValueDefaultsKey)
                fastIgnoredModels.remove(model)
                UserDefaults.standard.set(Array(fastIgnoredModels), forKey: Self.fastIgnoredDefaultsKey)
                setFastSupport(.supported)
                fastLabel = "yes"
            } else if accepted {
                UserDefaults.standard.removeObject(forKey: Self.fastWireValueDefaultsKey)
                fastIgnoredModels.insert(model)
                UserDefaults.standard.set(Array(fastIgnoredModels), forKey: Self.fastIgnoredDefaultsKey)
                setFastSupport(.supported)
                fastLabel = "accepted, but OpenAI reports normal speed"
            } else if let lastError {
                fastLabel = "failed (\(lastError.localizedDescription))"
            } else {
                fastLabel = "not available"
            }
        } else {
            fastLabel = "not offered for this model"
        }
        return "Connected · Reasoning: \(reasoningLabel) · Fast: \(fastLabel)"
    }

    // MARK: Networking helpers

    nonisolated private static func streamResponse(
        accessToken: String,
        prompt: String,
        options: ChatGPTPlanRequestOptions,
        onPartial: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> ChatGPTStreamResult {
        var request = URLRequest(url: responsesURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": options.model,
            "input": [["role": "user", "content": prompt]],
            "store": false,
            "stream": true
        ]
        if let effort = options.reasoningEffort {
            body["reasoning"] = ["effort": effort]
        }
        if let serviceTier = options.serviceTier {
            body["service_tier"] = serviceTier
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await httpSession.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 262_144 { break }
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw apiError(from: object, status: status, fallback: "ChatGPT request failed (HTTP \(status)).")
        }

        var result = ChatGPTStreamResult()
        var completed = false
        var pending = ""
        do {
            // Each server-sent event carries one JSON object on a single data line.
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                guard payload != "[DONE]" else { continue }
                let candidate = pending.isEmpty ? payload : pending + "\n" + payload
                guard let data = candidate.data(using: .utf8),
                      let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    pending = candidate.count > 4_194_304 ? "" : candidate
                    continue
                }
                pending = ""

                switch event["type"] as? String {
                case "response.output_text.delta":
                    if let delta = event["delta"] as? String, !delta.isEmpty {
                        result.text += delta
                        if let onPartial {
                            await onPartial(delta)
                        }
                    }
                case "response.completed":
                    completed = true
                    if let response = event["response"] as? [String: Any] {
                        result.serviceTier = response["service_tier"] as? String
                        result.reasoningEffort = (response["reasoning"] as? [String: Any])?["effort"] as? String
                    }
                case "response.failed":
                    throw apiError(from: event["response"] as? [String: Any], status: status, fallback: "ChatGPT could not complete the response.")
                case "error":
                    throw apiError(from: event, status: status, fallback: "ChatGPT could not complete the response.")
                case "response.incomplete":
                    let reason = ((event["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
                    throw ChatGPTPlanError(
                        code: "response_incomplete",
                        message: "ChatGPT stopped before finishing\(reason.map { " (\($0))" } ?? ""). Try again."
                    )
                default:
                    break
                }
                if completed { break }
            }
        } catch let error as ChatGPTPlanError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ChatGPTPlanError(code: "stream_interrupted", message: "The connection to ChatGPT was interrupted. Try again.")
        }
        guard completed else {
            throw ChatGPTPlanError(code: "stream_interrupted", message: "The ChatGPT response ended before completion. Try again.")
        }
        return result
    }

    nonisolated private static func formRequest(
        endpoint: String,
        fields: [(String, String)],
        expectsJSON: Bool = true
    ) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else {
            throw ChatGPTPlanError(code: "discovery_failed", message: "ChatGPT sign-in configuration could not be verified.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields
            .map { name, value in
                "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await controlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(status) else {
            throw apiError(from: object, status: status, fallback: "ChatGPT sign-in failed (HTTP \(status)).")
        }
        if expectsJSON, object == nil {
            throw ChatGPTPlanError(code: "invalid_token_response", message: "ChatGPT returned an invalid response. Please sign in again.", status: status)
        }
        return object ?? [:]
    }

    nonisolated private static func apiError(from object: [String: Any]?, status: Int, fallback: String) -> ChatGPTPlanError {
        // OAuth errors use {"error": "code", "error_description": "..."}; API errors nest an object.
        let nested = object?["error"] as? [String: Any]
        let details = nested ?? object
        let code = (object?["error"] as? String)
            ?? (details?["code"] as? String)
            ?? (details?["type"] as? String).flatMap { $0 == "error" ? nil : $0 }
            ?? "request_failed"
        var message = (details?["message"] as? String)
            ?? (object?["error_description"] as? String)
            ?? (object?["detail"] as? String)
            ?? fallback
        if code == ChatGPTPlanError.usageLimitCode {
            message = "You've reached your ChatGPT plan's usage limit for apps. RSSum won't switch to paid billing; wait for the limit to reset or manage usage at chatgpt.com/settings/usage."
        } else if status == 401, nested == nil, object?["error"] == nil {
            message = "ChatGPT rejected the saved sign-in. Sign in again in Settings → Summary Provider."
        }
        return ChatGPTPlanError(code: code, message: message, param: details?["param"] as? String, status: status)
    }

    nonisolated private static func writeDiagnostic(_ data: Data, named name: String) {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    nonisolated private static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

nonisolated struct ChatGPTStreamResult {
    var text = ""
    var serviceTier: String?
    var reasoningEffort: String?
}

extension ChatGPTPlanService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first {
                return window
            }
            if let scene {
                return ASPresentationAnchor(windowScene: scene)
            }
            return ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}

// MARK: - Loopback callback listener

/// Accepts OpenAI's redirect to http://127.0.0.1:<port>/auth/callback while the
/// sign-in sheet is open. Only the request carrying the expected state is used.
nonisolated final class ChatGPTLoopbackListener: @unchecked Sendable {
    private let expectedState: String
    private let queue = DispatchQueue(label: "com.joaovalente.RSSReaderApp.chatgpt.loopback")
    private var listener: NWListener?
    private var onCallback: (@Sendable (ChatGPTLoopbackCallback) -> Void)?
    private var delivered = false
    private var port: UInt16 = 0

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func setOnCallback(_ handler: @escaping @Sendable (ChatGPTLoopbackCallback) -> Void) {
        queue.sync { onCallback = handler }
    }

    /// Binds the preferred port, or any free loopback port when it is taken.
    func start(preferredPort: UInt16) async throws -> UInt16 {
        do {
            return try await start(port: NWEndpoint.Port(rawValue: preferredPort) ?? .any)
        } catch {
            return try await start(port: .any)
        }
    }

    private func start(port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        queue.sync { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let once = ChatGPTResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let bound = listener.port?.rawValue ?? port.rawValue
                    self?.port = bound
                    if once.claim() { continuation.resume(returning: bound) }
                case .failed(let error):
                    listener.cancel()
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() {
                        continuation.resume(throwing: ChatGPTPlanError(code: "callback_failed", message: "The sign-in listener stopped. Please try again."))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), on: connection)
            } else if isComplete || error != nil || buffer.count > 32_768 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard requestLine.count >= 2,
              requestLine[0] == "GET",
              host == "127.0.0.1:\(port)",
              let components = URLComponents(string: "http://127.0.0.1:\(port)\(requestLine[1])"),
              components.path == "/auth/callback" else {
            send(status: "404 Not Found", body: "Not found", on: connection)
            return
        }
        let items = components.queryItems ?? []
        let value: (String) -> String? = { name in items.first { $0.name == name }?.value }
        let states = items.filter { $0.name == "state" }
        guard !delivered, states.count == 1, states[0].value == expectedState else {
            send(status: "400 Bad Request", body: "This sign-in link is no longer valid. Return to RSSum and try again.", on: connection)
            return
        }
        delivered = true
        send(
            status: "200 OK",
            body: "<h1>Return to RSSum</h1><p>RSSum is finishing your ChatGPT connection. This window closes on its own.</p>",
            on: connection
        )
        onCallback?(ChatGPTLoopbackCallback(
            code: value("code"),
            clientID: value("client_id"),
            error: value("error"),
            errorDescription: value("error_description")
        ))
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let html = "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>RSSum</title><body style=\"font:17px -apple-system,system-ui;max-width:32rem;margin:18vh auto;padding:24px\">\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

nonisolated private final class ChatGPTResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

// MARK: - Keychain

nonisolated private enum ChatGPTPlanKeychain {
    static let service = "com.joaovalente.RSSReaderApp.chatgpt-plan"

    static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(for account: String) -> String? {
        data(for: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func set(_ string: String, for account: String) {
        set(Data(string.utf8), for: account)
    }

    static func set(_ data: Data, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Background summaries run while the device is locked, after first unlock.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        } else if status != errSecSuccess {
            print("⚠️ [ChatGPTPlanKeychain] Failed to save '\(account)': \(status)")
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Base64URL

nonisolated private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
