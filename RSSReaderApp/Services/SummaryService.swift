import Foundation
import Combine

class SummaryService {
    private var apiKey: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    
    init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? ""
    }
    
    func updateApiKey(_ newApiKey: String) {
        self.apiKey = newApiKey
    }
    
    func summarizeText(_ text: String, customPrompt: String? = nil) -> AnyPublisher<String, Never> {
        // Check if API key is available
        guard !apiKey.isEmpty else {
            return Just("API key not configured. Please add your Gemini API key in Settings.")
                .eraseToAnyPublisher()
        }
        
        // Prepare the URL with API key
        let urlString = "\(baseURL)?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            return Just("Invalid API URL")
                .eraseToAnyPublisher()
        }
        
        // Handle large text inputs
        var inputText = text
        let maxTextLength = 150000  // Adjust this based on API limits
        
        if inputText.count > maxTextLength {
            print("⚠️ SummaryService: Text exceeds maximum length (\(inputText.count) chars). Truncating to \(maxTextLength) chars.")
            inputText = String(inputText.prefix(maxTextLength))
        }
        
        // Prepare the request body
        let prompt: String
        if let customPrompt = customPrompt {
            // Use the custom prompt if provided
            prompt = customPrompt
        } else {
            // Default prompt for article summarization
            prompt = "Summarize the following text in a concise way, highlighting the key points: \(inputText)"
        }
        
        print("📱 SummaryService: Processing \(inputText.count) characters for summarization")
        
        let requestBody = GeminiRequest(contents: [GeminiContent(parts: [GeminiPart(text: prompt)])])
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            return Just("Error encoding request: \(error.localizedDescription)")
                .eraseToAnyPublisher()
        }
        
        return URLSession.shared.dataTaskPublisher(for: request)
            .map { $0.data }
            .decode(type: GeminiResponse.self, decoder: JSONDecoder())
            .map { response -> String in
                if let text = response.candidates?.first?.content.parts.first?.text {
                    return text
                } else if let errorMessage = response.error?.message {
                    return "Error: \(errorMessage)"
                } else {
                    return "No summary available"
                }
            }
            .replaceError(with: "Error generating summary")
            .eraseToAnyPublisher()
    }
}

// MARK: - Gemini API Models
struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
}

struct GeminiContent: Codable {
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String
}

struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let error: GeminiError?
}

struct GeminiCandidate: Decodable {
    let content: GeminiContent
}

struct GeminiError: Decodable {
    let code: Int
    let message: String
}
