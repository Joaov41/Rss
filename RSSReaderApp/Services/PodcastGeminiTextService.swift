#if os(iOS)
import Foundation

enum PodcastGeminiTextService {
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-lite-latest:generateContent"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.networkServiceType = .responsiveData
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private struct RequestBody: Encodable {
        let contents: [Content]
    }

    private struct ResponseBody: Decodable {
        let candidates: [Candidate]?
        let error: APIError?
    }

    private struct Candidate: Decodable {
        let content: Content
    }

    private struct Content: Codable {
        let parts: [Part]
    }

    private struct Part: Codable {
        let text: String
    }

    private struct APIError: Decodable {
        let message: String
    }

    static func generate(prompt: String, apiKey: String) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw SummaryServiceError.apiKeyMissing }
        guard let url = URL(string: "\(endpoint)?key=\(trimmedKey)") else {
            throw SummaryServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = min(120 + Double(prompt.count / 1_000) * 2, 300)
        request.httpBody = try JSONEncoder().encode(
            RequestBody(contents: [Content(parts: [Part(text: prompt)])])
        )

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let decodedError = try? JSONDecoder().decode(ResponseBody.self, from: data).error?.message
            throw NSError(
                domain: "PodcastGemini",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: decodedError ?? "Gemini returned HTTP \(httpResponse.statusCode)."]
            )
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        if let text = decoded.candidates?.first?.content.parts.first?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let message = decoded.error?.message {
            throw NSError(domain: "PodcastGemini", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        throw NSError(
            domain: "PodcastGemini",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Gemini returned no podcast response."]
        )
    }
}
#endif
