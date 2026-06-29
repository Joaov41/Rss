//
//  RedditOAuthManager.swift
//  RSSReaderApp
//
//  Handles Reddit OAuth authentication flow
//

import Foundation
import Combine
#if os(iOS)
import UIKit
import AuthenticationServices
#elseif os(macOS)
import AppKit
import AuthenticationServices
#endif

class RedditOAuthManager: NSObject, ObservableObject {

    // MARK: - OAuth Configuration

    // Client ID is now stored in user settings - set it in the Settings screen
    // Register your app at https://old.reddit.com/prefs/apps
    private var clientId: String {
        return persistenceManager.loadSettings().redditClientId
    }
    // MUST match your Reddit app's redirect URI exactly
    private let redirectURI = "redapp://auth"
    private let scope = "read,identity,mysubreddits,history,vote,submit"

    // OAuth endpoints - use standard authorize (not compact for mobile)
    private let authorizationURL = "https://www.reddit.com/api/v1/authorize"
    private let tokenURL = "https://www.reddit.com/api/v1/access_token"

    // MARK: - Properties

    @Published var isAuthenticated = false
    @Published var username: String = ""

    private let persistenceManager = PersistenceManager.shared
    private var cancellables = Set<AnyCancellable>()

    // Properties for automatic token refresh
    private var isRefreshing = false
    private let refreshLock = NSLock()

    #if os(iOS) || os(macOS)
    private var authSession: ASWebAuthenticationSession?
    #endif
    
    #if os(macOS)
    // Store pending auth state for macOS callback handling
    private var pendingAuthState: String?
    private var pendingAuthCompletion: ((Result<Void, Error>) -> Void)?
    #endif

    // MARK: - Initialization

    override init() {
        super.init()
        loadStoredCredentials()
    }

    // MARK: - Authentication Status

    func loadStoredCredentials() {
        let settings = persistenceManager.loadSettings()

        if !settings.redditAccessToken.isEmpty {
            isAuthenticated = true
            username = settings.redditUsername

            // Check if token is expired
            if let expiry = settings.redditTokenExpiry, expiry < Date() {
                print("🔐 RedditOAuth: Access token expired, will refresh on next request")
            }
        }
    }

    var hasValidToken: Bool {
        let settings = persistenceManager.loadSettings()
        guard !settings.redditAccessToken.isEmpty else { return false }

        if let expiry = settings.redditTokenExpiry {
            return expiry > Date()
        }
        return true
    }

    // MARK: - OAuth Flow

    func startOAuthFlow(completion: @escaping (Result<Void, Error>) -> Void) {
        // Validate client ID is set
        guard !clientId.isEmpty, clientId != "YOUR_CLIENT_ID_HERE" else {
            print("❌ RedditOAuth: Client ID not configured")
            completion(.failure(NSError(domain: "RedditOAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Please enter your Reddit Client ID in Settings first"])))
            return
        }

        // Generate random state for security
        let state = UUID().uuidString

        // Build authorization URL
        var components = URLComponents(string: authorizationURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "duration", value: "permanent"),
            URLQueryItem(name: "scope", value: scope)
        ]

        guard let authURL = components.url else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid authorization URL"])))
            return
        }

        print("🔐 RedditOAuth: Starting authentication flow...")
        print("🔐 RedditOAuth: Client ID: \(clientId.prefix(8))...")
        print("🔐 RedditOAuth: Redirect URI: \(redirectURI)")
        print("🔐 RedditOAuth: Auth URL: \(authURL.absoluteString)")

        #if os(iOS)
        startIOSAuthFlow(authURL: authURL, state: state, completion: completion)
        #elseif os(macOS)
        startMacOSAuthFlow(authURL: authURL, state: state, completion: completion)
        #endif
    }

    #if os(iOS)
    private func startIOSAuthFlow(authURL: URL, state: String, completion: @escaping (Result<Void, Error>) -> Void) {
        authSession = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "redapp"
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ RedditOAuth: Authentication failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            guard let callbackURL = callbackURL else {
                completion(.failure(NSError(domain: "RedditOAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No callback URL received"])))
                return
            }

            self.handleCallback(url: callbackURL, expectedState: state, completion: completion)
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        authSession?.start()
    }
    #endif

    #if os(macOS)
    private func startMacOSAuthFlow(authURL: URL, state: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // Prefer ASWebAuthenticationSession for reliable callback handling on macOS.
        authSession = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "redapp"
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ RedditOAuth: Authentication failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let callbackURL = callbackURL else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "RedditOAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No callback URL received"])))
                }
                return
            }

            DispatchQueue.main.async {
                self.handleCallback(url: callbackURL, expectedState: state, completion: completion)
            }
        }

        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false

        let started = authSession?.start() ?? false
        if started {
            pendingAuthState = nil
            pendingAuthCompletion = nil
            print("🔐 RedditOAuth: Started ASWebAuthenticationSession for authentication")
            return
        }

        // Fallback: open in default browser and handle URL scheme callback via onOpenURL.
        authSession = nil
        pendingAuthState = state
        pendingAuthCompletion = completion
        NSWorkspace.shared.open(authURL)
        print("🔐 RedditOAuth: Opened browser for authentication (fallback). Waiting for callback...")
    }
    
    /// Handle the OAuth callback URL on macOS (called from RSSReaderApp.onOpenURL)
    func handleMacOSCallback(url: URL) {
        guard let state = pendingAuthState,
              let completion = pendingAuthCompletion else {
            print("❌ RedditOAuth: No pending auth state found for callback")
            return
        }
        
        // Clear the pending state
        pendingAuthState = nil
        pendingAuthCompletion = nil
        
        // Use the existing handleCallback method
        handleCallback(url: url, expectedState: state, completion: completion)
    }
    #endif

    // MARK: - Callback Handling

    func handleCallback(url: URL, expectedState: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])))
            return
        }

        // Extract code and state
        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              let state = queryItems.first(where: { $0.name == "state" })?.value else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -4, userInfo: [NSLocalizedDescriptionKey: "Missing code or state in callback"])))
            return
        }

        // Verify state matches
        guard state == expectedState else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -5, userInfo: [NSLocalizedDescriptionKey: "State mismatch - possible CSRF attack"])))
            return
        }

        print("🔐 RedditOAuth: Received authorization code, exchanging for tokens...")

        // Exchange code for tokens
        exchangeCodeForTokens(code: code, completion: completion)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: tokenURL) else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -6, userInfo: [NSLocalizedDescriptionKey: "Invalid token URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Reddit requires Basic auth with client_id:empty_string (for installed apps)
        let credentials = "\(clientId):".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("RSS Reader App/1.0", forHTTPHeaderField: "User-Agent")

        // Build request body
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ RedditOAuth: Token exchange failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "RedditOAuth", code: -7, userInfo: [NSLocalizedDescriptionKey: "No data received from token endpoint"])))
                }
                return
            }

            do {
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                self.saveTokens(tokenResponse: tokenResponse)
                self.fetchUserIdentity(accessToken: tokenResponse.access_token)

                DispatchQueue.main.async {
                    self.isAuthenticated = true
                    completion(.success(()))
                }

                print("✅ RedditOAuth: Successfully authenticated with Reddit")
            } catch {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
                print("❌ RedditOAuth: Failed to decode token response: \(error). Body: \(bodyPreview)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - Token Refresh

    func refreshAccessToken(completion: @escaping (Result<String, Error>) -> Void) {
        var settings = persistenceManager.loadSettings()

        guard !settings.redditRefreshToken.isEmpty else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -8, userInfo: [NSLocalizedDescriptionKey: "No refresh token available"])))
            return
        }

        guard let url = URL(string: tokenURL) else {
            completion(.failure(NSError(domain: "RedditOAuth", code: -9, userInfo: [NSLocalizedDescriptionKey: "Invalid token URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let credentials = "\(clientId):".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("RSS Reader App/1.0", forHTTPHeaderField: "User-Agent")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: settings.redditRefreshToken)
        ]
        request.httpBody = bodyComponents.query?.data(using: .utf8)

        print("🔐 RedditOAuth: Refreshing access token...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                print("❌ RedditOAuth: Token refresh failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "RedditOAuth", code: -10, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                }
                return
            }

            do {
                let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                self.saveTokens(tokenResponse: tokenResponse)

                DispatchQueue.main.async {
                    print("✅ RedditOAuth: Successfully refreshed access token")
                    completion(.success(tokenResponse.access_token))
                }
            } catch {
                let bodyPreview = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
                print("❌ RedditOAuth: Failed to decode refresh response: \(error). Body: \(bodyPreview)")
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }

    // MARK: - Automatic Token Refresh

    /// Async version of token refresh for use with async/await
    func refreshAccessTokenAsync() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            refreshAccessToken { result in
                switch result {
                case .success(let token):
                    continuation.resume(returning: token)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Ensures the token is valid before making requests.
    /// Automatically refreshes the token if it's expired or expiring within 5 minutes.
    func ensureValidToken() async throws {
        let settings = persistenceManager.loadSettings()

        // Skip if not authenticated
        guard !settings.redditAccessToken.isEmpty else { return }

        // Check if token expires within 5 minutes (300 seconds)
        if let expiry = settings.redditTokenExpiry,
           expiry < Date().addingTimeInterval(300) {

            // Prevent concurrent refresh attempts
            refreshLock.lock()
            if isRefreshing {
                refreshLock.unlock()
                // Wait for ongoing refresh to complete
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                return
            }
            isRefreshing = true
            refreshLock.unlock()

            defer {
                refreshLock.lock()
                isRefreshing = false
                refreshLock.unlock()
            }

            _ = try await refreshAccessTokenAsync()
            print("🔐 RedditOAuth: Proactively refreshed token before expiry")
        }
    }

    /// Checks if token needs refresh (for use when a 401 is received)
    func needsTokenRefresh() -> Bool {
        let settings = persistenceManager.loadSettings()
        guard !settings.redditAccessToken.isEmpty else { return false }

        if let expiry = settings.redditTokenExpiry {
            // Token expired or expiring within 1 minute
            return expiry < Date().addingTimeInterval(60)
        }
        return false
    }

    // MARK: - User Identity

    private func fetchUserIdentity(accessToken: String) {
        guard let url = URL(string: "https://oauth.reddit.com/api/v1/me") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("RSS Reader App/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else { return }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let username = json["name"] as? String {
                var settings = self.persistenceManager.loadSettings()
                settings.redditUsername = username
                self.persistenceManager.saveSettings(settings)

                DispatchQueue.main.async {
                    self.username = username
                    print("✅ RedditOAuth: Logged in as u/\(username)")
                }
            }
        }.resume()
    }

    // MARK: - Token Storage

    private func saveTokens(tokenResponse: TokenResponse) {
        var settings = persistenceManager.loadSettings()
        settings.redditAccessToken = tokenResponse.access_token

        if let refreshToken = tokenResponse.refresh_token {
            settings.redditRefreshToken = refreshToken
        }

        // Calculate expiry time (Reddit tokens expire in 1 hour)
        let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in - 300)) // 5 min buffer
        settings.redditTokenExpiry = expiryDate

        persistenceManager.saveSettings(settings)
    }

    // MARK: - Logout

    func logout() {
        var settings = persistenceManager.loadSettings()
        settings.redditAccessToken = ""
        settings.redditRefreshToken = ""
        settings.redditTokenExpiry = nil
        settings.redditUsername = ""
        persistenceManager.saveSettings(settings)

        isAuthenticated = false
        username = ""

        print("🔐 RedditOAuth: Logged out")
    }

    // MARK: - Token Response Model

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

#if os(iOS) || os(macOS)
extension RedditOAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif os(macOS)
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}
#endif
