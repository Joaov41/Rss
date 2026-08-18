import Foundation

// MARK: - MLX JSON Repair Utilities
// These utilities help repair malformed JSON output from MLX models

enum MLXStructuredJSONKind {
    case infographic
    case whiteboard
}

struct MLXJSONRepairUtils {

    // MARK: - Main Repair Function

    /// Attempts to repair invalid JSON from MLX models by running it through another LLM
    static func repairInvalidJSONFromMLX(
        kind: MLXStructuredJSONKind,
        rawOutput: String,
        summaryProvider: AppSettings.SummaryProvider,
        performGeminiFallback: @escaping (String) async throws -> String
    ) async throws -> Data {
        guard summaryProvider == .mlxLocal else {
            throw NSError(domain: "MLXRepair", code: 2, userInfo: [NSLocalizedDescriptionKey: "MLX repair is only available when MLX Local is selected."])
        }

        let clipped = String(rawOutput.prefix(12_000))
        let keys: String
        let extraRules: String
        switch kind {
        case .infographic:
            keys = "title,subtitle,focus,palette,statTiles,barSections,sentiment,sentimentBand,majorThemes,themes,keyTopics,notableTrends,takeaway,topPosts"
            extraRules = "- barSections \"value\" must be a plain integer (no quotes, no %, no decimals)\n- sentiment values (positive, neutral, negative) must be plain integers\n- statTiles \"value\" should be a string"
        case .whiteboard:
            keys = "sessionTitle,sessionContext,whatWeKnow,openQuestions,takeaways,painPoints,hotTakes,connections,ideasToExplore,keyPosts,bottomLine"
            extraRules = ""
        }

        var repairPrompt = "You are a strict JSON fixer. Output ONLY the fixed JSON, nothing else.\n\n"
        repairPrompt += "Convert the following model output into a single valid JSON object.\n"
        repairPrompt += "- Use double quotes for all keys and strings\n"
        repairPrompt += "- No trailing commas\n"
        repairPrompt += "- No markdown code fences\n"
        repairPrompt += "- No text before or after the JSON\n"
        repairPrompt += "- Keep the same meaning, but ensure it parses as JSON\n"
        repairPrompt += "- Only use these top-level keys: \(keys)\n"
        if !extraRules.isEmpty {
            repairPrompt += "\(extraRules)\n"
        }
        repairPrompt += "\nModel output to fix:\n\(clipped)"

        let repaired = try await performGeminiFallback(repairPrompt)
        guard let data = repaired.data(using: .utf8) else {
            throw NSError(domain: "MLXRepair", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not convert repaired JSON to data."])
        }
        return data
    }

    // MARK: - JSON Parsing with Multiple Candidates

    /// Parses LLM JSON output, trying multiple repair strategies
    static func parseLLMJSONDictionary(from data: Data, domain: String) throws -> [String: Any] {
        guard let rawString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: domain, code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid \(domain.lowercased()) text encoding."])
        }

        let candidates = makeJSONParseCandidates(from: rawString)
        guard !candidates.isEmpty else {
            throw NSError(domain: domain, code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not locate a JSON object in the \(domain.lowercased()) response."])
        }

        var lastError: Error?
        for candidate in candidates {
            guard let jsonData = candidate.data(using: .utf8) else { continue }
            do {
                if let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                    return json
                }
            } catch {
                lastError = error
            }
        }

        let detail = lastError?.localizedDescription ?? "Unknown JSON parsing error."
        throw NSError(domain: domain, code: 9, userInfo: [NSLocalizedDescriptionKey: "Could not parse \(domain.lowercased()) JSON. \(detail)"])
    }

    /// Creates multiple JSON parsing candidates with progressive fixups
    static func makeJSONParseCandidates(from rawString: String) -> [String] {
        var base = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        base = stripMarkdownFences(from: base)
        if let extracted = extractJSONObjectSubstring(from: base) {
            base = extracted
        }

        var candidates: [String] = []
        func appendCandidate(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }
        }

        appendCandidate(base)

        let normalizedQuotes = normalizeUnicodeQuotes(in: base)
        appendCandidate(normalizedQuotes)

        let withoutTrailingCommas = removeTrailingCommas(in: normalizedQuotes)
        appendCandidate(withoutTrailingCommas)

        let withQuotedKeys = quoteUnquotedKeys(in: withoutTrailingCommas)
        appendCandidate(withQuotedKeys)

        let withSingleQuoteFixups = convertSingleQuotedStrings(in: withQuotedKeys)
        appendCandidate(withSingleQuoteFixups)

        let withNumericRangeFixups = replaceNumericRanges(in: withSingleQuoteFixups)
        appendCandidate(withNumericRangeFixups)

        // MLX models often produce malformed numeric values - try fixing those
        let withMLXNumericFixups = fixMLXNumericValues(in: withNumericRangeFixups)
        appendCandidate(withMLXNumericFixups)

        return candidates
    }

    // MARK: - Individual Fixup Functions

    /// Removes markdown code fences from text
    static func stripMarkdownFences(from text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        output = output.replacingOccurrences(of: "(?s)^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "(?s)\\s*```$", with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: "```", with: "")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts JSON object substring from text
    static func extractJSONObjectSubstring(from text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[firstBrace...lastBrace])
    }

    /// Normalizes Unicode quotes to standard ASCII quotes
    static func normalizeUnicodeQuotes(in text: String) -> String {
        var result = text
        // Left/right double quotes
        result = result.replacingOccurrences(of: "\u{201C}", with: "\"") // "
        result = result.replacingOccurrences(of: "\u{201D}", with: "\"") // "
        result = result.replacingOccurrences(of: "\u{201E}", with: "\"") // „
        result = result.replacingOccurrences(of: "\u{201F}", with: "\"") // ‟
        // Left/right single quotes
        result = result.replacingOccurrences(of: "\u{2018}", with: "'") // '
        result = result.replacingOccurrences(of: "\u{2019}", with: "'") // '
        result = result.replacingOccurrences(of: "\u{201A}", with: "'") // ‚
        result = result.replacingOccurrences(of: "\u{201B}", with: "'") // ‛
        return result
    }

    /// Removes trailing commas before closing braces/brackets
    static func removeTrailingCommas(in text: String) -> String {
        var output = text
        for _ in 0..<4 {
            let updated = output.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
            if updated == output { break }
            output = updated
        }
        return output
    }

    /// Quotes unquoted keys in JSON-like text
    static func quoteUnquotedKeys(in text: String) -> String {
        // Converts: { title: "x" } -> { "title": "x" }
        return text.replacingOccurrences(
            of: "([{,]\\s*)([A-Za-z_][A-Za-z0-9_]*)\\s*:",
            with: "$1\"$2\":",
            options: .regularExpression
        )
    }

    /// Converts single-quoted strings to double-quoted
    static func convertSingleQuotedStrings(in text: String) -> String {
        // Converts common pseudo-JSON to strict JSON:
        // {'key': 'value', 'arr': ['a','b']} -> {"key": "value", "arr": ["a","b"]}
        var output = text
        output = output.replacingOccurrences(
            of: "([{,]\\s*)'([^'\\n]+)'\\s*:",
            with: "$1\"$2\":",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "([:\\[{,]\\s*)'([^'\\n]*)'(?=\\s*[,}\\]])",
            with: "$1\"$2\"",
            options: .regularExpression
        )
        return output
    }

    /// Replaces numeric ranges with single numbers
    static func replaceNumericRanges(in text: String) -> String {
        // Some small local models will copy schema hints like `0-100` into output. Convert ranges to a single number.
        return text.replacingOccurrences(
            of: "(?<!\")\\b(\\d+)\\s*-\\s*\\d+\\b(?!\")",
            with: "$1",
            options: .regularExpression
        )
    }

    /// Fixes MLX-specific numeric value issues
    static func fixMLXNumericValues(in text: String) -> String {
        var output = text
        // Remove percent signs from numbers (e.g., 72% -> 72, "72%" -> "72")
        output = output.replacingOccurrences(
            of: "(\\d+)\\s*%",
            with: "$1",
            options: .regularExpression
        )
        // Convert decimal numbers to integers where they appear as JSON values (e.g., 72.0 -> 72)
        output = output.replacingOccurrences(
            of: ":\\s*(\\d+)\\.0+(?=\\s*[,}\\]])",
            with: ": $1",
            options: .regularExpression
        )
        // Fix numbers with trailing text (e.g., "value": 50 points -> "value": 50)
        output = output.replacingOccurrences(
            of: ":\\s*(\\d+)\\s+[a-zA-Z]+(?=\\s*[,}\\]])",
            with: ": $1",
            options: .regularExpression
        )
        return output
    }

    // MARK: - Utility for cleaning output

    /// Cleans MLX output by stripping common artifacts
    static func cleanMLXOutput(_ output: String) -> String {
        var result = output
        result = result.replacingOccurrences(of: "<end_of_turn>", with: "")
        result = result.replacingOccurrences(of: "</s>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
