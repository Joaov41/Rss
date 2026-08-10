import Foundation

/// Plain-text content attached to a prompt.
///
/// The runtime does not parse files directly; callers extract text from a `.txt`,
/// `.pdf`, or another document format and pass the contents here.
public struct PromptAttachment: Sendable {
    public let filename: String
    public let content: String

    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}
