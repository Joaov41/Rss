import Foundation
import Combine
import SwiftUI

class FaviconService {
    // Cache to store loaded favicons
    private var faviconCache: [String: URL] = [:]
    private var imageDictionary: [String: UIImage] = [:]
    
    // Standard paths to try when searching for a favicon
    private let faviconPaths = [
        "/favicon.ico",
        "/favicon.png",
        "/apple-touch-icon.png",
        "/apple-touch-icon-precomposed.png"
    ]
    
    public init() {}
    
    // Get favicon URL for a domain
    public func getFaviconURL(for urlString: String) -> AnyPublisher<URL?, Error> {
        // Check cache first
        if let baseURL = extractBaseURL(from: urlString),
           let cachedURL = faviconCache[baseURL] {
            return Just(cachedURL)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Try to construct favicon URL from domain
        return extractFaviconURL(from: urlString)
            .flatMap { [weak self] faviconURL -> AnyPublisher<URL?, Error> in
                guard let self = self, let faviconURL = faviconURL, let baseURL = self.extractBaseURL(from: urlString) else {
                    return Just(nil)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                // Cache the result
                self.faviconCache[baseURL] = faviconURL
                return Just(faviconURL)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    // Try multiple favicon paths and return the first successful one
    private func extractFaviconURL(from urlString: String) -> AnyPublisher<URL?, Error> {
        guard let baseURL = extractBaseURL(from: urlString),
              let url = URL(string: "https://\(baseURL)") else {
            return Just(nil)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Try Google's favicon service first (most reliable)
        let googleFaviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(baseURL)&sz=64")
        
        // If we have Google's favicon service, use it directly
        if let googleURL = googleFaviconURL {
            return Just(googleURL)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // If Google service URL construction failed, try direct favicon paths
        let publishers = faviconPaths.compactMap { path -> AnyPublisher<URL?, Error>? in
            guard let faviconURL = URL(string: "\(url.absoluteString)\(path)") else { return nil }
            
            return URLSession.shared.dataTaskPublisher(for: faviconURL)
                .map { data, response -> URL? in
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 200 {
                        return faviconURL
                    }
                    return nil
                }
                .catch { _ in Just(nil) }
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Try each path and return the first successful one
        return Publishers.MergeMany(publishers)
            .compactMap { $0 }
            .first()
            .replaceError(with: nil)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    // Extract base domain from URL
    public func extractBaseURL(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else {
            // Try adding https:// prefix if missing
            guard let url = URL(string: "https://\(urlString)") else {
                return nil
            }
            return url.host
        }
        return url.host
    }
    
    // Create a placeholder image with domain's initial letter
    public func createPlaceholderImage(for domain: String) -> UIImage {
        let initial = String(domain.prefix(1).uppercased())
        
        let size = CGSize(width: 30, height: 30)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Draw background
            let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemRed]
            let colorIndex = abs(domain.hash) % colors.count
            colors[colorIndex].setFill()
            
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: size.width / 2)
            path.fill()
            
            // Draw text
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 16),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
            
            let textRect = CGRect(x: 0, y: 7, width: size.width, height: size.height)
            initial.draw(in: textRect, withAttributes: attributes)
        }
    }
    
    // Gets a UIImage for a domain (either from cache or creates a placeholder)
    public func getImageForDomain(_ domain: String) -> UIImage {
        if let cachedImage = imageDictionary[domain] {
            return cachedImage
        }
        
        let placeholderImage = createPlaceholderImage(for: domain)
        imageDictionary[domain] = placeholderImage
        return placeholderImage
    }
    
    // Synchronous method to get favicon URL (for use in SwiftUI)
    public func getFaviconURLSync(for domain: String) -> URL? {
        // Check cache first
        if let baseURL = extractBaseURL(from: domain),
           let cachedURL = faviconCache[baseURL] {
            return cachedURL
        }
        
        // If not cached, create a Google favicon URL (reliable default)
        if let baseURL = extractBaseURL(from: domain) {
            let googleFaviconURL = URL(string: "https://www.google.com/s2/favicons?domain=\(baseURL)&sz=64")
            
            // Cache it for future use
            if let googleURL = googleFaviconURL {
                faviconCache[baseURL] = googleURL
            }
            
            return googleFaviconURL
        }
        
        return nil
    }
}
