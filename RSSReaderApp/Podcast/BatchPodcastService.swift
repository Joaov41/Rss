import Foundation

typealias BatchPodcastTextGenerator = @MainActor (_ prompt: String, _ title: String) async throws -> String

final class BatchPodcastService {
    private let generator: BatchPodcastTextGenerator
    private let maximumReportsPerPrompt = 6

    init(generator: @escaping BatchPodcastTextGenerator) {
        self.generator = generator
    }

    func generateEpisode(
        from context: BatchPodcastContext,
        progress: ((BatchPodcastProgress) -> Void)? = nil
    ) async throws -> PodcastEpisode {
        try Task.checkCancellation()
        let reports = try await reduceEvidence(from: context, progress: progress)
        try Task.checkCancellation()

        progress?(.mergingEvidence)
        let consolidated = try await consolidate(reports)
        let evidence = makeEvidenceReferences(from: consolidated)

        progress?(.outlining)
        let outline = try await makeOutline(context: context, evidence: evidence)

        progress?(.writingScript)
        var rawScript = try await generator(
            finalPrompt(context: context, outline: outline, evidence: evidence),
            "Batch Podcast Script"
        )

        do {
            progress?(.validating)
            let episode = try normalize(rawScript, context: context, evidence: evidence)
            progress?(.ready)
            return episode
        } catch {
            try Task.checkCancellation()
            progress?(.repairingJSON)
            rawScript = try await generator(
                repairPrompt(rawScript: rawScript, error: error, context: context, evidence: evidence),
                "Repair Batch Podcast JSON"
            )
            progress?(.validating)
            let repaired = try normalize(rawScript, context: context, evidence: evidence)
            progress?(.ready)
            return repaired
        }
    }

    private func reduceEvidence(
        from context: BatchPodcastContext,
        progress: ((BatchPodcastProgress) -> Void)?
    ) async throws -> [PodcastEvidenceReport] {
        var reports: [PodcastEvidenceReport] = []
        reports.reserveCapacity(context.evidenceChunks.count)

        for (index, chunk) in context.evidenceChunks.enumerated() {
            try Task.checkCancellation()
            progress?(.analyzingChunk(current: index + 1, total: context.evidenceChunks.count))
            let raw = try await generator(evidencePrompt(chunk: chunk, context: context), "Podcast Evidence \(index + 1)")
            reports.append(parseEvidence(raw: raw, chunk: chunk))
        }
        return reports
    }

    private func consolidate(_ reports: [PodcastEvidenceReport]) async throws -> [PodcastEvidenceReport] {
        guard reports.count > maximumReportsPerPrompt else { return reports }
        var current = reports

        while current.count > maximumReportsPerPrompt {
            var next: [PodcastEvidenceReport] = []
            for start in stride(from: 0, to: current.count, by: maximumReportsPerPrompt) {
                try Task.checkCancellation()
                let group = Array(current[start..<min(start + maximumReportsPerPrompt, current.count)])
                let raw = try await generator(
                    mergePrompt(reports: group),
                    "Merge Podcast Evidence"
                )
                if let drafts = BatchPodcastJSONDecoder.decode([PodcastEvidenceDraft].self, from: raw), !drafts.isEmpty {
                    let ids = Set(group.flatMap(\.sourceIDs))
                    let claims = drafts.flatMap(\.claims).map {
                        PodcastEvidenceClaim(text: String($0.prefix(1_000)), sourceIDs: Array(ids).sorted())
                    }
                    next.append(
                        PodcastEvidenceReport(
                            chunkID: group.map(\.chunkID).joined(separator: "+"),
                            sourceIDs: Array(ids).sorted(),
                            claims: claims.isEmpty ? group.flatMap(\.claims) : claims,
                            tensions: drafts.flatMap(\.tensions),
                            unknowns: drafts.flatMap(\.unknowns)
                        )
                    )
                } else {
                    next.append(
                        PodcastEvidenceReport(
                            chunkID: group.map(\.chunkID).joined(separator: "+"),
                            sourceIDs: Array(Set(group.flatMap(\.sourceIDs))).sorted(),
                            claims: group.flatMap(\.claims),
                            tensions: group.flatMap(\.tensions),
                            unknowns: group.flatMap(\.unknowns)
                        )
                    )
                }
            }
            current = next
        }
        return current
    }

    private func makeOutline(
        context: BatchPodcastContext,
        evidence: [PodcastEvidenceReference]
    ) async throws -> PodcastOutline {
        let raw = try await generator(
            outlinePrompt(context: context, evidence: evidence),
            "Outline Batch Podcast"
        )
        if let draft = BatchPodcastJSONDecoder.decode(PodcastOutlineDraft.self, from: raw) {
            let allowed = Set(evidence.map(\.id))
            return PodcastOutline(
                title: PodcastSpokenTextCleaner.clean(draft.title),
                summary: PodcastSpokenTextCleaner.clean(draft.summary),
                beats: draft.beats.map {
                    PodcastOutlineBeat(
                        title: PodcastSpokenTextCleaner.clean($0.title),
                        talkingPoints: $0.talkingPoints.map(PodcastSpokenTextCleaner.clean),
                        evidenceRefs: $0.evidenceRefs.filter { allowed.contains($0) }
                    )
                }
            )
        }

        return PodcastOutline(
            title: context.title,
            summary: context.overallSummary.map(PodcastSpokenTextCleaner.clean) ?? "A grounded conversation about the saved batch.",
            beats: evidence.prefix(8).map {
                PodcastOutlineBeat(
                    title: $0.id,
                    talkingPoints: $0.claims,
                    evidenceRefs: [$0.id]
                )
            }
        )
    }

    private func normalize(
        _ raw: String,
        context: BatchPodcastContext,
        evidence: [PodcastEvidenceReference]
    ) throws -> PodcastEpisode {
        guard let draft = BatchPodcastJSONDecoder.decode(PodcastDraftEpisode.self, from: raw) else {
            throw BatchPodcastError.invalidScript("expected Codable JSON")
        }
        guard draft.schemaVersion == PodcastEpisode.currentSchemaVersion else {
            throw BatchPodcastError.invalidScript("unsupported schema version")
        }
        if !draft.sourceDigest.isEmpty, draft.sourceDigest != context.sourceDigest {
            throw BatchPodcastError.invalidScript("source digest mismatch")
        }
        guard !draft.turns.isEmpty else {
            throw BatchPodcastError.invalidScript("the script contained no turns")
        }

        let evidenceByID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        let knownSourceIDs = context.knownSourceIDs
        var turns: [PodcastTurn] = []

        for draftTurn in draft.turns {
            let spoken = PodcastSpokenTextCleaner.clean(
                knownSourceIDs.sorted { $0.count > $1.count }
                    .reduce(draftTurn.text) { $0.replacingOccurrences(of: $1, with: "") }
            )
            guard !spoken.isEmpty else { continue }

            let sourceIDs = Array(
                Set(draftTurn.evidenceRefs.flatMap { reference in
                    evidenceByID[reference]?.sourceIDs ?? (knownSourceIDs.contains(reference) ? [reference] : [])
                })
                    .intersection(knownSourceIDs)
            ).sorted()
            turns.append(
                PodcastTurn(
                    id: draftTurn.id,
                    speaker: draftTurn.speaker,
                    text: spoken,
                    sourceIDs: sourceIDs
                )
            )
        }

        guard !turns.isEmpty else {
            throw BatchPodcastError.invalidScript("all turns were empty after spoken-text cleanup")
        }
        guard turns.contains(where: { !$0.sourceIDs.isEmpty }) else {
            throw BatchPodcastError.invalidScript("the script did not retain grounded evidence")
        }

        let episode = PodcastEpisode(
            id: draft.id,
            title: PodcastSpokenTextCleaner.clean(draft.title).isEmpty ? context.title : PodcastSpokenTextCleaner.clean(draft.title),
            summary: PodcastSpokenTextCleaner.clean(draft.summary),
            sourceDigest: context.sourceDigest,
            createdAt: draft.createdAt,
            estimatedDuration: 0,
            turns: turns
        )
        let limited = PodcastEpisodeWordLimiter.limit(episode)
        let duration = Double(limited.spokenWordCount) / 150.0 * 60.0
        return limited.withTurns(limited.turns, duration: duration)
    }

    private func parseEvidence(raw: String, chunk: BatchPodcastEvidenceChunk) -> PodcastEvidenceReport {
        if let decoded = BatchPodcastJSONDecoder.decode(PodcastEvidenceDraft.self, from: raw) {
            let claims = decoded.claims
                .map { PodcastEvidenceClaim(text: String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_500)), sourceIDs: chunk.sourceIDs) }
                .filter { !$0.text.isEmpty }
            if !claims.isEmpty {
                return PodcastEvidenceReport(
                    chunkID: chunk.id,
                    sourceIDs: chunk.sourceIDs,
                    claims: claims,
                    tensions: decoded.tensions.map { String($0.prefix(500)) },
                    unknowns: decoded.unknowns.map { String($0.prefix(500)) }
                )
            }
        }

        let fallback = PodcastSpokenTextCleaner.clean(String(raw.prefix(2_000)))
        return PodcastEvidenceReport(
            chunkID: chunk.id,
            sourceIDs: chunk.sourceIDs,
            claims: [PodcastEvidenceClaim(
                text: fallback.isEmpty ? "The saved evidence chunk contained no structured claim." : fallback,
                sourceIDs: chunk.sourceIDs
            )],
            tensions: [],
            unknowns: ["The evidence reduction was not structured; retain the saved text as the source of truth."]
        )
    }

    private func makeEvidenceReferences(from reports: [PodcastEvidenceReport]) -> [PodcastEvidenceReference] {
        reports.enumerated().map {
            PodcastEvidenceReference(
                id: "evidence-\($0.offset + 1)",
                sourceIDs: $0.element.sourceIDs,
                claims: $0.element.claims.map(\.text).filter { !$0.isEmpty },
                tensions: $0.element.tensions,
                unknowns: $0.element.unknowns
            )
        }
    }

    private func evidencePrompt(chunk: BatchPodcastEvidenceChunk, context: BatchPodcastContext) -> String {
        let labels = chunk.sourceIDs.compactMap { id in
            context.sources.first(where: { $0.sourceID == id }).map { "- \($0.title) [\($0.kind.rawValue)]" }
        }.joined(separator: "\n")
        return """
        Reduce only this saved Batch Summary evidence chunk into compact JSON for a grounded podcast.
        Do not fetch anything, add facts, infer counts, or claim consensus. Preserve disagreement and uncertainty.

        Chunk ID: \(chunk.id)
        Captured sources:
        \(labels.isEmpty ? "(none)" : labels)

        Saved evidence:
        \(chunk.text)

        Return only JSON:
        {"claims":["compact factual claim"],"tensions":["disagreement or uncertainty"],"unknowns":["what the evidence does not establish"]}
        Keep the response under 350 words. Do not include source IDs in the response.
        """
    }

    private func mergePrompt(reports: [PodcastEvidenceReport]) -> String {
        """
        Merge these already-reduced evidence reports into a compact set of claims. Use only the supplied text.
        Preserve disagreement and uncertainty. Do not add counts, consensus, prevalence, or facts.

        \(bounded(json(reports), maximumCharacters: 28_000))

        Return only JSON shaped like:
        [{"claims":["claim"],"tensions":["tension"],"unknowns":["unknown"]}]
        """
    }

    private func outlinePrompt(context: BatchPodcastContext, evidence: [PodcastEvidenceReference]) -> String {
        """
        Build a compact conversational outline for a two-host podcast titled \(context.title).
        Use only the supplied saved summaries and reduced evidence. Do not invent counts, consensus, or conclusions.
        Keep evidence references internal and copy them exactly.

        Saved summaries:
        \(bounded(json(context.perItemSummaries), maximumCharacters: 20_000))

        Overall summary:
        \(bounded(context.overallSummary ?? "No overall summary was saved.", maximumCharacters: 4_000))

        Reduced evidence:
        \(bounded(json(evidence), maximumCharacters: 24_000))

        Return only JSON:
        {"title":"short title","summary":"one-paragraph summary","beats":[{"title":"theme","talkingPoints":["point"],"evidenceRefs":["evidence-1"]}]}
        """
    }

    private func finalPrompt(
        context: BatchPodcastContext,
        outline: PodcastOutline,
        evidence: [PodcastEvidenceReference]
    ) -> String {
        """
        Write a natural two-host podcast script about \(context.title).

        Grounding rules:
        - Use only the saved summaries, outline, and reduced evidence below.
        - Do not invent facts, numbers, prevalence, or consensus. If evidence disagrees, say that it is mixed or uncertain.
        - Do not speak source IDs, URLs, Markdown, headings, speaker labels, or production directions.
        - Keep evidenceRefs in JSON only. They are internal metadata and must never appear in spoken text.
        - Target 10–18 conversational turns and roughly 800–1,050 spoken words. A shorter episode is acceptable when the evidence is limited; do not pad it with invented detail. Do not exceed 1,060 words.
        - Host ordering may be natural; use only hostA and hostB.

        Outline:
        \(bounded(json(outline), maximumCharacters: 16_000))

        Reduced evidence:
        \(bounded(json(evidence), maximumCharacters: 24_000))

        Return only one valid JSON object:
        {"id":"UUID","schemaVersion":1,"title":"short title","summary":"short spoken summary","sourceDigest":"\(context.sourceDigest)","createdAt":"ISO-8601 date","estimatedDuration":0,"turns":[{"id":"UUID","speaker":"hostA","text":"spoken words only","evidenceRefs":["evidence-1"]}]}
        """
    }

    private func repairPrompt(
        rawScript: String,
        error: Error,
        context: BatchPodcastContext,
        evidence: [PodcastEvidenceReference]
    ) -> String {
        """
        Repair the attempted podcast JSON below. Return only valid schema version 1 JSON.
        Validation issue: \(error.localizedDescription)
        Keep the sourceDigest exactly \(context.sourceDigest). Use only hostA and hostB. Keep only valid evidenceRefs from the supplied evidence. Remove URLs, Markdown, headings, source IDs, and production directions from spoken text. Do not add unsupported counts or consensus. Target 10–18 turns and approximately 800–1,050 words, but do not pad limited evidence and never exceed 1,060 words.

        Allowed evidence:
        \(bounded(json(evidence), maximumCharacters: 24_000))

        Attempted response:
        \(String(rawScript.prefix(28_000)))

        Return exactly one JSON object with `turns` containing `speaker`, `text`, and `evidenceRefs`.
        """
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "{}"
    }

    private func bounded(_ value: String, maximumCharacters: Int) -> String {
        String(value.prefix(max(1, maximumCharacters)))
    }
}

private struct PodcastEvidenceDraft: Codable {
    let claims: [String]
    let tensions: [String]
    let unknowns: [String]
}

private struct PodcastOutlineDraft: Codable {
    let title: String
    let summary: String
    let beats: [PodcastOutlineDraftBeat]
}

private struct PodcastOutlineDraftBeat: Codable {
    let title: String
    let talkingPoints: [String]
    let evidenceRefs: [String]
}

private struct PodcastEvidenceReference: Codable {
    let id: String
    let sourceIDs: [String]
    let claims: [String]
    let tensions: [String]
    let unknowns: [String]
}
