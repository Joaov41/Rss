// swift-litert-lm — lightweight .eml text extraction.

import CoreFoundation
import Foundation

public enum EMLTextExtractor {
  public static func extract(from data: Data) -> String? {
    guard let raw = decode(data, charset: nil) else { return nil }
    let headers = headerBlock(in: raw)
    var lines: [String] = [
      "From: \(decodedHeader(named: "From", in: headers))",
      "To: \(decodedHeader(named: "To", in: headers))"
    ]

    for name in ["Cc", "Bcc", "Reply-To", "Return-Path"] {
      let value = decodedHeader(named: name, in: headers)
      if !value.isEmpty { lines.append("\(name): \(value)") }
    }

    let date = decodedHeader(named: "Date", in: headers)
    if !date.isEmpty { lines.append("Date: \(date)") }

    lines.append("Subject: \(decodedHeader(named: "Subject", in: headers))")
    lines.append("")
    lines.append(extractBody(from: bodyBlock(in: raw), headers: headers))
    return lines.joined(separator: "\n")
  }

  private static func headerBlock(in raw: String) -> String {
    if let range = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") {
      return String(raw[..<range.lowerBound])
    }
    return raw
  }

  private static func bodyBlock(in raw: String) -> String {
    if let range = raw.range(of: "\r\n\r\n") ?? raw.range(of: "\n\n") {
      return String(raw[range.upperBound...])
    }
    return ""
  }

  private static func decodedHeader(named name: String, in headers: String) -> String {
    decodeMIMEWords(header(named: name, in: headers))
  }

  private static func header(named name: String, in headers: String) -> String {
    let unfolded = headers.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\n\t", with: " ")
      .replacingOccurrences(of: "\n ", with: " ")
    let prefix = "\(name):"
    for line in unfolded.components(separatedBy: "\n") {
      if line.lowercased().hasPrefix(prefix.lowercased()) {
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    return ""
  }

  private static func extractBody(from body: String, headers: String) -> String {
    guard let boundary = boundary(in: headers) else {
      return decodedPartBody(body, headers: headers, contentType: header(named: "Content-Type", in: headers))
    }

    var plainParts: [String] = []
    var htmlParts: [String] = []

    for chunk in body.components(separatedBy: "--\(boundary)") {
      let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedChunk.isEmpty, trimmedChunk != "--" else { continue }

      let partHeaders = headerBlock(in: chunk)
      let lowerHeaders = partHeaders.lowercased()
      guard !lowerHeaders.contains("content-disposition: attachment") else { continue }

      let contentType = header(named: "Content-Type", in: partHeaders).lowercased()
      let partBody = bodyBlock(in: chunk)
      if contentType.contains("multipart/") {
        let nested = extractBody(from: partBody, headers: partHeaders)
        if !nested.isEmpty { plainParts.append(nested) }
      } else if contentType.contains("text/plain") {
        plainParts.append(stripSignatureArtifacts(decodedPartBody(partBody, headers: partHeaders, contentType: contentType)))
      } else if contentType.contains("text/html") {
        htmlParts.append(stripSignatureArtifacts(stripHTML(decodedPartBody(partBody, headers: partHeaders, contentType: contentType))))
      }
    }

    if !plainParts.isEmpty { return plainParts.joined(separator: "\n") }
    if !htmlParts.isEmpty { return htmlParts.joined(separator: "\n") }
    return sanitizeFallback(body)
  }

  private static func boundary(in headers: String) -> String? {
    let contentType = header(named: "Content-Type", in: headers)
    guard let range = contentType.range(of: #"boundary="?([^";]+)"?"#, options: .regularExpression) else {
      return nil
    }
    let match = String(contentType[range])
    return match
      .replacingOccurrences(of: "boundary=", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
  }

  private static func decodedPartBody(_ body: String, headers: String, contentType: String) -> String {
    let transfer = header(named: "Content-Transfer-Encoding", in: headers).lowercased()
    let charset = charset(in: contentType)
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

    if transfer == "base64",
      let data = Data(
        base64Encoded: trimmed.replacingOccurrences(of: "\\s", with: "", options: .regularExpression),
        options: [.ignoreUnknownCharacters])
    {
      return decode(data, charset: charset) ?? ""
    }

    if transfer == "quoted-printable" {
      return decode(quotedPrintable: trimmed, charset: charset)
    }

    return trimmed
  }

  private static func charset(in contentType: String) -> String? {
    guard let range = contentType.range(of: #"charset="?([^";]+)"?"#, options: .regularExpression) else {
      return nil
    }
    return String(contentType[range])
      .replacingOccurrences(of: "charset=", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
  }

  private static func decode(_ data: Data, charset: String?) -> String? {
    if let charset,
      let encoding = stringEncoding(for: charset),
      let string = String(data: data, encoding: encoding)
    {
      return string
    }

    let normalized = charset?.lowercased()
    let encodings: [String.Encoding] = switch normalized {
    case "iso-8859-1", "latin1", "latin-1": [.isoLatin1, .utf8]
    case "us-ascii", "ascii": [.ascii, .utf8, .isoLatin1]
    default: [.utf8, .isoLatin1, .ascii]
    }
    for encoding in encodings {
      if let string = String(data: data, encoding: encoding) { return string }
    }
    return String(data: data, encoding: .utf8)
  }

  private static func stringEncoding(for charset: String) -> String.Encoding? {
    let trimmed = charset.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(trimmed as CFString)
    guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
  }

  private static func decodeMIMEWords(_ value: String) -> String {
    let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    var output = value
    let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()

    for match in matches {
      guard let whole = Range(match.range(at: 0), in: value),
        let charsetRange = Range(match.range(at: 1), in: value),
        let encodingRange = Range(match.range(at: 2), in: value),
        let payloadRange = Range(match.range(at: 3), in: value)
      else { continue }

      let charset = String(value[charsetRange])
      let encoding = String(value[encodingRange]).lowercased()
      let payload = String(value[payloadRange])
      let decoded: String?
      if encoding == "b", let data = Data(base64Encoded: payload) {
        decoded = decode(data, charset: charset)
      } else {
        decoded = decode(quotedPrintable: payload.replacingOccurrences(of: "_", with: " "), charset: charset)
      }
      if let decoded { output.replaceSubrange(whole, with: decoded) }
    }

    return output
  }

  private static func decode(quotedPrintable text: String, charset: String?) -> String {
    var bytes: [UInt8] = []
    let scalars = Array(
      text.replacingOccurrences(of: "=\r\n", with: "")
        .replacingOccurrences(of: "=\n", with: "").utf8)
    var index = 0
    while index < scalars.count {
      if scalars[index] == UInt8(ascii: "="), index + 2 < scalars.count,
        let hi = hexValue(scalars[index + 1]), let lo = hexValue(scalars[index + 2])
      {
        bytes.append((hi << 4) | lo)
        index += 3
      } else {
        bytes.append(scalars[index])
        index += 1
      }
    }
    return decode(Data(bytes), charset: charset) ?? text
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    default: return nil
    }
  }

  private static func stripHTML(_ html: String) -> String {
    var text = html
      .replacingOccurrences(of: "&nbsp;", with: " ")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
    text = text.replacingOccurrences(of: #"(?is)<head[\s\S]*?</head>"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?is)<(script|style).*?</\1>"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)</p>"#, with: "\n\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func sanitizeFallback(_ raw: String) -> String {
    let headerRegex = try? NSRegularExpression(pattern: "^content-[^:]+:", options: [.caseInsensitive])
    let base64CharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    let lines = raw.components(separatedBy: CharacterSet.newlines).compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("--") else { return nil }
      if let headerRegex,
        headerRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) != nil
      {
        return nil
      }
      let base64Trimmed = trimmed.trimmingCharacters(in: base64CharacterSet)
      if base64Trimmed.isEmpty && trimmed.count >= 40 { return nil }
      return trimmed
    }
    return stripHTML(lines.joined(separator: "\n"))
  }

  private static func stripSignatureArtifacts(_ text: String) -> String {
    let imageURLPattern = #"https?://[^\s]+?\.(?:png|jpe?g|gif|bmp|heic|heif)(?:\?[^\s]*)?"#
    let cidLinePattern = #"(?i)^\s*(?:\[?cid:[^\]\s>]+(?:\])?|<cid:[^>]+>)(?:\s*(?:<[^>]+>|\$\>|[,\s;])*)*$"#
    let cidTokenPattern = #"(?i)\[?cid:[^\]\s>]+(?:\])?"#
    let base64LikeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=|_-$!;:.,")

    let cleaned = text.components(separatedBy: CharacterSet.newlines).compactMap { line -> String? in
      var working = line
      if working.range(of: "urldefense.com", options: .caseInsensitive) != nil { return nil }
      if working.range(of: cidLinePattern, options: .regularExpression) != nil { return nil }

      working = working.replacingOccurrences(of: cidTokenPattern, with: "", options: .regularExpression)
      working = working.replacingOccurrences(
        of: imageURLPattern, with: "", options: [.regularExpression, .caseInsensitive])

      var trimmed = working.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return nil }
      if trimmed == "$>" || trimmed == "<>" || trimmed == "[]" || trimmed == "()" { return nil }

      let lowercased = trimmed.lowercased()
      if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") { return nil }

      let noWhitespace = trimmed.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil
      if noWhitespace && trimmed.count >= 20 && trimmed.rangeOfCharacter(from: base64LikeCharacters.inverted) == nil {
        return nil
      }

      trimmed = trimmed.replacingOccurrences(of: "<>", with: "")
      trimmed = trimmed.replacingOccurrences(of: "[]", with: "")
      trimmed = trimmed.replacingOccurrences(of: "()", with: "")
      trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
