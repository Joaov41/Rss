// swift-litert-lm — document text extraction for chat context.
//
// LiteRT-LM does not consume PDF, TXT, or EML files directly. This layer turns
// those documents into text so callers can send them through the normal text
// path while still keeping a file-oriented API.

import Foundation
import UniformTypeIdentifiers

public struct LiteRTDocument: Equatable, Sendable {
  public var name: String?
  public var text: String

  public init(text: String, name: String? = nil) {
    self.name = name
    self.text = text
  }

  public init(data: Data, name: String? = nil, type: UTType? = nil) throws {
    self.name = name
    self.text = try DocumentTextExtractor.extractText(from: data, name: name, type: type)
  }

  public init(fileURL url: URL, type: UTType? = nil) throws {
    self.name = url.lastPathComponent
    self.text = try DocumentTextExtractor.extractText(from: url, type: type)
  }
}

public enum DocumentTextExtractorError: LocalizedError {
  case unsupportedDocumentType(String?)
  case unreadableText(String?)
  case emptyDocument(String?)

  public var errorDescription: String? {
    switch self {
    case .unsupportedDocumentType(let name):
      return "Unsupported document type\(name.map { " for \($0)" } ?? "")."
    case .unreadableText(let name):
      return "Could not read text from \(name ?? "document")."
    case .emptyDocument(let name):
      return "No text was extracted from \(name ?? "document")."
    }
  }
}

public enum DocumentTextExtractor {
  public static func extractText(from url: URL, type explicitType: UTType? = nil) throws -> String {
    let values = try? url.resourceValues(forKeys: [.typeIdentifierKey])
    let resourceType = values?.typeIdentifier.flatMap { UTType($0) }
    let inferredType = explicitType ?? resourceType ?? UTType(filenameExtension: url.pathExtension)
    let data = try Data(contentsOf: url)
    return try extractText(from: data, name: url.lastPathComponent, type: inferredType)
  }

  public static func extractText(
    from data: Data, name: String? = nil, type explicitType: UTType? = nil
  ) throws -> String {
    let ext = name.flatMap { URL(fileURLWithPath: $0).pathExtension.lowercased() }
    let inferredType = explicitType ?? ext.flatMap { UTType(filenameExtension: $0) }
    let text: String

    if isPDF(type: inferredType, extension: ext) {
      text = PDFTextExtractor.extractText(from: data)
    } else if isEML(type: inferredType, extension: ext) {
      text = EMLTextExtractor.extract(from: data) ?? ""
    } else if isText(type: inferredType, extension: ext) {
      text = loadPlainText(from: data)
    } else {
      throw DocumentTextExtractorError.unsupportedDocumentType(name)
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw DocumentTextExtractorError.emptyDocument(name) }
    return trimmed
  }

  private static func isPDF(type: UTType?, extension ext: String?) -> Bool {
    type?.conforms(to: .pdf) == true || ext == "pdf"
  }

  private static func isEML(type: UTType?, extension ext: String?) -> Bool {
    guard ext != "eml" else { return true }
    let identifier = type?.identifier.lowercased() ?? ""
    return identifier.contains("message") && identifier.contains("rfc822")
  }

  private static func isText(type: UTType?, extension ext: String?) -> Bool {
    if let type {
      if type.conforms(to: .plainText) || type.conforms(to: .text) {
        return true
      }
      if type.conforms(to: .utf8PlainText) || type.conforms(to: .utf16PlainText) {
        return true
      }
    }
    let textExtensions: Set<String> = [
      "txt", "text", "md", "markdown", "csv", "json", "log", "xml", "html", "htm",
      "yaml", "yml", "swift", "py", "js", "ts", "java", "c", "cpp", "m", "mm", "sh"
    ]
    return ext.map { textExtensions.contains($0) } ?? false
  }

  private static func loadPlainText(from data: Data) -> String {
    let encodings: [String.Encoding] = [
      .utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .unicode, .macOSRoman, .isoLatin1
    ]

    for encoding in encodings {
      if let string = String(data: data, encoding: encoding) { return string }
    }
    return String(decoding: data, as: UTF8.self)
  }
}

extension Array where Element == LiteRTDocument {
  var liteRTPromptContext: String {
    let sections = self.compactMap { document -> String? in
      let body = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return nil }
      if let name = document.name, !name.isEmpty {
        return "Document (\(name)):\n\(body)"
      }
      return "Document:\n\(body)"
    }
    return sections.joined(separator: "\n\n")
  }
}
