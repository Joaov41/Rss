#if false
//
//  GlobalSummaryService.swift (DISABLED)
//  Reason: GlobalSummaryService and JSON models are now inlined in AppState.swift
//          to avoid Target Membership issues and duplicate type definitions.
//  To re-enable modular files later:
//   1) Remove the inline “Inline Global Summary (models + service)” block from AppState.swift
//   2) Enable this file and Models/GlobalSummaryModels.swift in the app target
//   3) Build
//

import Foundation
import Combine

final class GlobalSummaryService {
    private let summaryService: SummaryService
    private let redditService: RedditService
    
    init(summaryService: SummaryService, redditService: RedditService) {
        self.summaryService = summaryService
        self.redditService = redditService
    }
    
    // MARK: - Public API
    
    func summarizeArticlesGlobally(articles: [Article]) -> AnyPublisher<GlobalSummaryResult, Never> {
        fatalError("Disabled file - see AppState.swift inline implementation")
    }
    
    func summarizeRedditGlobally(posts: [RedditPost], topComments: Int = 3) -> AnyPublisher<GlobalSummaryResult, Never> {
        fatalError("Disabled file - see AppState.swift inline implementation")
    }
}
#endif
