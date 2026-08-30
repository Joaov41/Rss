// Copyright © 2026

import Foundation

public protocol Downloader: Sendable {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}

public protocol Tokenizer: Sendable {
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String
    func convertTokenToId(_ token: String) -> Int?
    func convertIdToToken(_ id: Int) -> String?

    var bosToken: String? { get }
    var eosToken: String? { get }
    var unknownToken: String? { get }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int]
}

public protocol TokenizerLoader: Sendable {
    func load(from directory: URL) async throws -> any Tokenizer
}
