#if false
//
//  GlobalSummaryModels.swift (DISABLED)
//  Reason: Types are now inlined in AppState.swift to avoid Target Membership issues and duplicate type errors.
//  To re-enable modular files later:
//   1) Remove the inline "Inline Global Summary (models + service)" block from AppState.swift
//   2) Enable this file and Services/GlobalSummaryService.swift in the app target
//   3) Build
//

import Foundation

public struct GlobalSummaryItem: Codable, Identifiable {
    public let id = UUID()
    public let subject: String
    public let summary: String
}

public struct GlobalSummaryResult: Codable {
    public let source: String
    public let summaries: [GlobalSummaryItem]
    public let error: String?
    
    public init(source: String, summaries: [GlobalSummaryItem], error: String? = nil) {
        self.source = source
        self.summaries = summaries
        self.error = error
    }
    
    public static func errorResult(source: String, message: String) -> GlobalSummaryResult {
        return GlobalSummaryResult(source: source, summaries: [], error: message)
    }
}
#endif
