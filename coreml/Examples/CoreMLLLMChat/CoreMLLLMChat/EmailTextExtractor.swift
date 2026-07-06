import Foundation
import UIKit

enum EmailTextExtractor {
    enum ExtractorError: LocalizedError {
        case emptyMessage
        case unreadableMessage

        var errorDescription: String? {
            switch self {
            case .emptyMessage:
                return "The email file is empty."
            case .unreadableMessage:
                return "The email file could not be decoded."
            }
        }
    }

    static func extractText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw ExtractorError.emptyMessage }

        let rawMessage = decodeLatin1(data)
        let rendered = renderMessage(rawMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty else { throw ExtractorError.unreadableMessage }
        return rendered
    }

    private static func renderMessage(_ rawMessage: String) -> String {
        let (headersText, bodyText) = splitHeadersAndBody(in: rawMessage)
        let headers = parseHeaders(headersText)
        let rawContent = extractBody(from: bodyText, headers: headers)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = cleanExtractedBody(rawContent)

        var lines: [String] = []
        for key in ["subject", "from", "to", "date"] {
            guard let value = headers[key], !value.isEmpty else { continue }
            lines.append("\(key.capitalized): \(decodeEncodedHeader(value))")
        }

        if !content.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append(content)
        }

        return lines.joined(separator: "\n")
    }

    private static func cleanExtractedBody(_ text: String) -> String {
        let normalized = normalizeNewlines(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return normalized }

        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cleaned: [String] = []
        var index = 0
        var substantiveLineCount = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if isQuotedReplyBoundary(line: trimmed, remainingLines: Array(lines[index...])) {
                break
            }

            if isDisclaimerBoundary(line: trimmed), !cleaned.isEmpty {
                break
            }

            if isEmailBoilerplateBoundary(line: trimmed), substantiveLineCount > 0 {
                break
            }

            if isSignatureLine(line: trimmed), substantiveLineCount > 1 {
                break
            }

            if trimmed.hasPrefix(">") {
                index += 1
                continue
            }

            if shouldDropNoiseLine(trimmed) {
                index += 1
                continue
            }

            cleaned.append(line)
            if isSubstantiveLine(trimmed) {
                substantiveLineCount += 1
            }
            index += 1
        }

        let collapsed = collapseBlankLines(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? normalized : collapsed
    }

    private static func isEmailBoilerplateBoundary(line: String) -> Bool {
        let lowercased = line.lowercased()
        let patterns = [
            "how was your concierge experience",
            "your cargo concierge",
            "[sent from front]",
            "sent from front",
            "find us on:",
            "unsubscribe",
            "view in browser"
        ]
        return patterns.contains(where: { lowercased.hasPrefix($0) || lowercased.contains($0) })
    }

    private static func isSignatureLine(line: String) -> Bool {
        let lowercased = line.lowercased()
        let signatures = [
            "regards,",
            "best regards,",
            "kind regards,",
            "thanks,",
            "thank you,",
            "sincerely,",
            "best,"
        ]
        return signatures.contains(lowercased)
    }

    private static func shouldDropNoiseLine(_ line: String) -> Bool {
        if line.isEmpty { return false }
        let lowercased = line.lowercased()
        if lowercased.hasPrefix("[survey]") || lowercased.hasPrefix("[cid:") {
            return true
        }
        if lowercased.contains("urldefense.com") {
            return true
        }
        return false
    }

    private static func isSubstantiveLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if shouldDropNoiseLine(trimmed) { return false }
        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    private static func isQuotedReplyBoundary(line: String, remainingLines: [String]) -> Bool {
        let lowercased = line.lowercased()
        if lowercased.isEmpty { return false }

        if lowercased.hasPrefix("on "), lowercased.hasSuffix(" wrote:") {
            return true
        }

        if lowercased.contains("original message") || lowercased.contains("forwarded message") {
            return true
        }

        if lowercased.hasPrefix("from:") || lowercased.hasPrefix("de:") {
            let lookahead = remainingLines.prefix(5)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let hasReplyHeaderBlock =
                lookahead.contains(where: { $0.hasPrefix("sent:") || $0.hasPrefix("date:") }) &&
                lookahead.contains(where: { $0.hasPrefix("to:") || $0.hasPrefix("subject:") || $0.hasPrefix("cc:") })
            if hasReplyHeaderBlock {
                return true
            }
        }

        if isSeparatorLine(lowercased) {
            let lookahead = remainingLines.dropFirst().prefix(4)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if lookahead.contains(where: { $0.hasPrefix("from:") || $0.hasPrefix("de:") || $0.hasPrefix("on ") }) {
                return true
            }
        }

        return false
    }

    private static func isDisclaimerBoundary(line: String) -> Bool {
        let lowercased = line.lowercased()
        let patterns = [
            "this email and any attachments",
            "this e-mail and any attachments",
            "the information contained in this email",
            "the information contained in this e-mail",
            "confidentiality notice",
            "intended recipient",
            "privileged and confidential",
            "disclaimer:"
        ]
        return patterns.contains(where: { lowercased.hasPrefix($0) || lowercased.contains($0) })
    }

    private static func collapseBlankLines(_ lines: [String]) -> String {
        var output: [String] = []
        var previousWasBlank = false

        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                if previousWasBlank { continue }
                previousWasBlank = true
                output.append("")
            } else {
                previousWasBlank = false
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private static func isSeparatorLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "-_")
        return line.unicodeScalars.allSatisfy { allowed.contains($0) } && line.count >= 5
    }

    private static func extractBody(from rawBody: String, headers: [String: String]) -> String {
        let disposition = parseHeaderValue(headers["content-disposition"]).value
        if disposition == "attachment" { return "" }

        let contentType = parseHeaderValue(headers["content-type"])
        let transferEncoding = headers["content-transfer-encoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if contentType.value.hasPrefix("multipart/"), let boundary = contentType.parameters["boundary"], !boundary.isEmpty {
            let extracted = splitMultipartBody(rawBody, boundary: boundary)
                .compactMap(extractPart)

            if contentType.value == "multipart/alternative" {
                return extracted.first(where: { $0.contentType == "text/plain" })?.text
                    ?? extracted.first(where: { $0.contentType == "text/html" })?.text
                    ?? extracted.first?.text
                    ?? ""
            }

            return extracted.map(\.text).joined(separator: "\n\n")
        }

        if contentType.value == "message/rfc822" {
            return renderMessage(rawBody)
        }

        let decodedData = decodeTransferEncodedBody(rawBody, transferEncoding: transferEncoding)
        let charset = contentType.parameters["charset"] ?? "utf-8"
        let decodedText = decodeBodyText(decodedData, charset: charset)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if contentType.value == "text/html" {
            return stripHTML(decodedText)
        }

        if contentType.value.hasPrefix("text/") || contentType.value.isEmpty {
            return decodedText
        }

        return ""
    }

    private static func extractPart(_ rawPart: String) -> (contentType: String, text: String)? {
        let (headersText, bodyText) = splitHeadersAndBody(in: rawPart)
        let headers = parseHeaders(headersText)
        let contentType = parseHeaderValue(headers["content-type"]).value
        let text = extractBody(from: bodyText, headers: headers)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        return (contentType, text)
    }

    private static func splitHeadersAndBody(in rawMessage: String) -> (String, String) {
        let normalized = normalizeNewlines(rawMessage)

        if let range = normalized.range(of: "\n\n") {
            let headers = String(normalized[..<range.lowerBound])
            let body = String(normalized[range.upperBound...])
            return (headers, body)
        }

        return ("", normalized)
    }

    private static func parseHeaders(_ headersText: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentName: String?

        for line in normalizeNewlines(headersText).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let currentName {
                headers[currentName, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
            currentName = name
        }

        return headers
    }

    private static func parseHeaderValue(_ rawValue: String?) -> (value: String, parameters: [String: String]) {
        guard let rawValue else { return ("", [:]) }

        let segments = splitSemicolonSeparated(rawValue)
        let base = segments.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        var parameters: [String: String] = [:]

        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<equals]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = segment[segment.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            parameters[key] = value
        }

        return (base, parameters)
    }

    private static func splitSemicolonSeparated(_ rawValue: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false

        for character in rawValue {
            if character == "\"" {
                inQuotes.toggle()
            }

            if character == ";", !inQuotes {
                parts.append(current)
                current = ""
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            parts.append(current)
        }

        return parts
    }

    private static func splitMultipartBody(_ rawBody: String, boundary: String) -> [String] {
        let delimiter = "--\(boundary)"
        let closingDelimiter = "\(delimiter)--"
        let normalized = normalizeNewlines(rawBody)
        var parts: [String] = []
        var currentLines: [String] = []
        var collecting = false

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == delimiter || line == closingDelimiter {
                if collecting {
                    let part = currentLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty {
                        parts.append(part)
                    }
                    currentLines.removeAll(keepingCapacity: true)
                }

                if line == closingDelimiter { break }
                collecting = true
                continue
            }

            if collecting {
                currentLines.append(line)
            }
        }

        return parts
    }

    private static func decodeTransferEncodedBody(_ body: String, transferEncoding: String) -> Data {
        switch transferEncoding {
        case "base64":
            let compact = body
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return Data(base64Encoded: compact) ?? encodeLatin1(body)
        case "quoted-printable":
            return decodeQuotedPrintable(body)
        default:
            return encodeLatin1(body)
        }
    }

    private static func decodeBodyText(_ data: Data, charset: String) -> String {
        for encoding in candidateEncodings(for: charset) {
            if let value = String(data: data, encoding: encoding) {
                return normalizeNewlines(value)
            }
        }

        return normalizeNewlines(decodeLatin1(data))
    }

    private static func candidateEncodings(for charset: String) -> [String.Encoding] {
        let normalized = charset
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "utf-8", "utf8":
            return [.utf8]
        case "us-ascii", "ascii":
            return [.ascii, .utf8]
        case "iso-8859-1", "latin1", "latin-1":
            return [.isoLatin1, .windowsCP1252, .utf8]
        case "windows-1252", "cp1252":
            return [.windowsCP1252, .isoLatin1, .utf8]
        default:
            return [.utf8, .windowsCP1252, .isoLatin1]
        }
    }

    private static func decodeQuotedPrintable(_ text: String) -> Data {
        var bytes: [UInt8] = []
        let scalars = Array(normalizeNewlines(text).unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == "=" {
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    index += 2
                    continue
                }

                if index + 2 < scalars.count,
                   let upper = hexNibble(scalars[index + 1]),
                   let lower = hexNibble(scalars[index + 2]) {
                    bytes.append((upper << 4) | lower)
                    index += 3
                    continue
                }
            }

            bytes.append(UInt8(scalar.value & 0xFF))
            index += 1
        }

        return Data(bytes)
    }

    private static func decodeEncodedHeader(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }

        let nsValue = value as NSString
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length))
        guard !matches.isEmpty else { return value }

        var decoded = value
        for match in matches.reversed() {
            guard match.numberOfRanges == 4 else { continue }
            let charset = nsValue.substring(with: match.range(at: 1))
            let encodingFlag = nsValue.substring(with: match.range(at: 2)).lowercased()
            let payload = nsValue.substring(with: match.range(at: 3))

            let payloadData: Data
            if encodingFlag == "b" {
                payloadData = Data(base64Encoded: payload) ?? Data()
            } else {
                let qpReady = payload.replacingOccurrences(of: "_", with: " ")
                payloadData = decodeQuotedPrintable(qpReady)
            }

            let replacement = decodeBodyText(payloadData, charset: charset)
            if let range = Range(match.range, in: decoded) {
                decoded.replaceSubrange(range, with: replacement)
            }
        }

        return decoded
    }

    private static func stripHTML(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else {
            return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }

        if let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            return normalizeNewlines(attributed.string)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func decodeLatin1(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func encodeLatin1(_ text: String) -> Data {
        text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data(text.utf8)
    }

    private static func hexNibble(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 48...57:
            return UInt8(scalar.value - 48)
        case 65...70:
            return UInt8(scalar.value - 55)
        case 97...102:
            return UInt8(scalar.value - 87)
        default:
            return nil
        }
    }
}
