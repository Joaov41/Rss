//
//  PodcastDiscoveryService.swift
//  RSSReaderApp
//
//  Searches Apple's public podcast catalog and returns the publisher RSS feed
//  URL so discovered shows continue through the app's normal feed pipeline.
//

import Foundation

struct PodcastSearchResult: Identifiable, Equatable, Sendable {
    let collectionID: Int64?
    let title: String
    let publisher: String
    let feedURL: URL
    let artworkURL: URL?
    let genre: String?
    let episodeCount: Int?

    var id: String { feedURL.absoluteString }
}

enum PodcastDiscoveryError: LocalizedError, Equatable {
    case invalidSearch
    case searchUnavailable
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidSearch:
            return "Enter a podcast or creator name to search."
        case .searchUnavailable:
            return "Podcast search is temporarily unavailable. Try again later."
        case .malformedResponse:
            return "The podcast catalog returned a response the app could not understand."
        }
    }
}

actor PodcastDiscoveryService {
    static let shared = PodcastDiscoveryService()

    private struct SearchResponse: Decodable {
        let results: [SearchItem]
    }

    private struct SearchItem: Decodable {
        let collectionId: Int64?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let artworkUrl100: String?
        let primaryGenreName: String?
        let trackCount: Int?
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query rawQuery: String, countryCode: String? = Locale.current.region?.identifier) async throws -> [PodcastSearchResult] {
        let url = try Self.searchURL(query: rawQuery, countryCode: countryCode)
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw PodcastDiscoveryError.searchUnavailable
            }
            return try Self.parseSearchResults(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PodcastDiscoveryError {
            throw error
        } catch {
            throw PodcastDiscoveryError.searchUnavailable
        }
    }

    static func searchURL(query rawQuery: String, countryCode: String?, limit: Int = 25) throws -> URL {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw PodcastDiscoveryError.invalidSearch }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        var queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        if let countryCode {
            let normalizedCountry = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if normalizedCountry.count == 2 {
                queryItems.append(URLQueryItem(name: "country", value: normalizedCountry))
            }
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw PodcastDiscoveryError.invalidSearch }
        return url
    }

    static func parseSearchResults(_ data: Data) throws -> [PodcastSearchResult] {
        let response: SearchResponse
        do {
            response = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw PodcastDiscoveryError.malformedResponse
        }

        var seenFeeds = Set<String>()
        return response.results.compactMap { item in
            guard let rawTitle = item.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTitle.isEmpty,
                  let rawFeedURL = item.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let feedURL = URL(string: rawFeedURL),
                  let scheme = feedURL.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return nil
            }

            let canonicalFeed = canonicalFeedURL(feedURL)
            guard seenFeeds.insert(canonicalFeed).inserted else { return nil }

            let publisher = item.artistName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "Unknown publisher"
            let artwork = item.artworkUrl600 ?? item.artworkUrl100

            return PodcastSearchResult(
                collectionID: item.collectionId,
                title: rawTitle,
                publisher: publisher,
                feedURL: feedURL,
                artworkURL: artwork.flatMap(URL.init(string:)),
                genre: item.primaryGenreName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                episodeCount: item.trackCount
            )
        }
    }

    private static func canonicalFeedURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? url.absoluteString
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
