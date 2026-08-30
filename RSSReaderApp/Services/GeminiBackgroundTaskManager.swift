#if os(iOS)
import Foundation
import Combine
import BackgroundTasks
import OSLog
import UIKit
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Background task manager that keeps Gemini operations running while the app is backgrounded or locked.
/// Mirrors the production-tested manager in the sample app and adds optional widget refresh support.
final class GeminiBackgroundTaskManager {
    static let shared = GeminiBackgroundTaskManager()

    private let logger = Logger(subsystem: "com.joaovalente.rssreader", category: "GeminiBackgroundTask")
    private let stateQueue = DispatchQueue(label: "com.joaovalente.rssreader.backgroundTask.state")

    private let bundleIdentifierPrefix: String = {
        if let id = Bundle.main.bundleIdentifier, !id.isEmpty {
            return id
        }
        return "com.joaovalente.rssreader"
    }()

    private lazy var continuedTaskIdentifier = "\(bundleIdentifierPrefix).geminiTask"
    private lazy var processingTaskIdentifier = "\(bundleIdentifierPrefix).geminiProcessing"
    private lazy var summarizationTaskIdentifier = "\(bundleIdentifierPrefix).summarization"
    private lazy var refreshTaskIdentifier = "\(bundleIdentifierPrefix).geminiRefresh"

    private let legacyBundleIdentifierPrefix = "com.joaovalente.rssreader"

    private var legacyContinuedTaskIdentifier: String { "\(legacyBundleIdentifierPrefix).geminiTask" }
    private var legacyProcessingTaskIdentifier: String { "\(legacyBundleIdentifierPrefix).geminiProcessing" }
    private var legacySummarizationTaskIdentifier: String { "\(legacyBundleIdentifierPrefix).summarization" }
    private var legacyRefreshTaskIdentifier: String { "\(legacyBundleIdentifierPrefix).geminiRefresh" }

    private var isRegistered = false
    private weak var activeHandle: GeminiBackgroundTaskHandle?
    private var dependentHandles: [ObjectIdentifier: GeminiBackgroundTaskHandle] = [:]
    private var activeTask: BGTask?
    private var activeLongRunningTask: BGProcessingTask?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private let widgetRefreshInterval: TimeInterval = 5 * 60
    private var pendingWidgetRefresh = false

    enum TaskType {
        case processing
        case summarization
    }

    private enum TaskKind {
        case continued
        case processing
        case summarization
        case refresh
    }

    private func identifiers(for kind: TaskKind) -> [String] {
        let primary: String
        let legacy: String

        switch kind {
        case .continued:
            primary = continuedTaskIdentifier
            legacy = legacyContinuedTaskIdentifier
        case .processing:
            primary = processingTaskIdentifier
            legacy = legacyProcessingTaskIdentifier
        case .summarization:
            primary = summarizationTaskIdentifier
            legacy = legacySummarizationTaskIdentifier
        case .refresh:
            primary = refreshTaskIdentifier
            legacy = legacyRefreshTaskIdentifier
        }

        return primary == legacy ? [primary] : [primary, legacy]
    }

    func taskIdentifier(for type: TaskType) -> String {
        switch type {
        case .processing: return processingTaskIdentifier
        case .summarization: return summarizationTaskIdentifier
        }
    }

    func legacyTaskIdentifier(for type: TaskType) -> String {
        switch type {
        case .processing: return legacyProcessingTaskIdentifier
        case .summarization: return legacySummarizationTaskIdentifier
        }
    }

    private init() { }

    /// Register handlers and observers; call once during app launch.
    func prepareForLaunch() {
        registerAllHandlers()
        registerLifecycleObservers()
        scheduleWidgetRefreshIfIdle()
    }

    /// Begin a user-initiated background task (iOS 26+). Dependent requests reuse the active session.
    @available(iOS 26.0, *)
    func beginTask(title: String, subtitle: String, totalUnitCount: Int64 = 100) -> GeminiBackgroundTaskHandle? {
        registerAllHandlers()

        let handle: GeminiBackgroundTaskHandle = stateQueue.sync {
            let isRoot = self.activeHandle == nil
            let newHandle = GeminiBackgroundTaskHandle(manager: self, totalUnitCount: totalUnitCount, isRootHandle: isRoot)
            if isRoot {
                self.activeHandle = newHandle
            } else {
                self.dependentHandles[ObjectIdentifier(newHandle)] = newHandle
            }
            return newHandle
        }

        handle.reportProgress(completedUnitCount: 1)

        if handle.isRootHandle {
            handle.setRequiresSystemSignal(true)
            do {
                try submitContinuedRequest(title: title, subtitle: subtitle)
                handle.notifyTaskStarted()
            } catch {
                handle.setRequiresSystemSignal(false)
                handle.notifyTaskStarted()
                logger.error("❌ Failed to submit BGContinuedProcessingTaskRequest: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            logger.info("ℹ️ Reusing existing Gemini background task (dependent request)")
            handle.notifyTaskStarted()
        }

        return handle
    }

    /// Begin a long-running background task that continues while the device is locked.
    func beginLongRunningTask(identifier: String, title: String) -> GeminiBackgroundTaskHandle {
        registerAllHandlers()

        let handle: GeminiBackgroundTaskHandle = stateQueue.sync {
            let isRoot = self.activeHandle == nil
            let newHandle = GeminiBackgroundTaskHandle(manager: self, totalUnitCount: 100, isRootHandle: isRoot)
            newHandle.taskIdentifier = identifier

            if isRoot {
                self.activeHandle = newHandle
            } else {
                self.dependentHandles[ObjectIdentifier(newHandle)] = newHandle
            }
            return newHandle
        }

        if handle.isRootHandle {
            if #available(iOS 26.0, *) {
                handle.setRequiresSystemSignal(true)
                do {
                    try submitContinuedRequest(title: title, subtitle: "Background execution")
                    logger.info("✅ Submitted iOS 26+ continued processing task: \(title)")
                    submitProcessingRequest(identifier: identifier, title: title)
                    handle.notifyTaskStarted()
                } catch {
                    handle.setRequiresSystemSignal(false)
                    handle.notifyTaskStarted()
                    logger.error("❌ Failed to submit BGContinuedProcessingTaskRequest: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                handle.notifyTaskStarted()
                logger.info("✅ Started UIBackgroundTask (~30 sec protection): \(title)")
            }
        } else {
            logger.info("ℹ️ Attached dependent Gemini task '\(title)' to existing background session")
            handle.notifyTaskStarted()
        }

        return handle
    }

    /// Wait until there are no active Gemini background tasks. If timeout is nil, waits indefinitely.
    @discardableResult
    func waitUntilIdle(timeout: TimeInterval? = nil) async -> Bool {
        let pollInterval: UInt64 = 150_000_000 // 0.15s
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        while true {
            let isIdle = stateQueue.sync {
                self.activeHandle == nil && self.activeLongRunningTask == nil && self.dependentHandles.isEmpty
            }
            if isIdle { return true }

            if let deadline, Date() >= deadline {
                return false
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func registerAllHandlers() {
        guard !isRegistered else { return }

        logger.info("🔧 Registering background task handlers…")

        if #available(iOS 26.0, *) {
            self.identifiers(for: .continued).forEach { identifier in
                BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                    self?.configureContinuedTask(task: task)
                }
                logger.info("✅ Registered continued processing task: \(identifier)")
            }
        }

        self.identifiers(for: .processing).forEach { identifier in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                self?.configureProcessingTask(task: task as! BGProcessingTask)
            }
        }

        self.identifiers(for: .summarization).forEach { identifier in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                self?.configureProcessingTask(task: task as! BGProcessingTask)
            }
        }

        self.identifiers(for: .refresh).forEach { identifier in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                self?.configureRefreshTask(task: task as! BGAppRefreshTask)
            }
        }

        isRegistered = true
        logger.info("✅ Registered all background task handlers")
    }

    private func registerLifecycleObservers() {
        guard backgroundObserver == nil else { return }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.handlesSnapshot().forEach { $0.applicationDidEnterBackground() }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.handlesSnapshot().forEach { $0.applicationWillEnterForeground() }
        }
    }

    @available(iOS 26.0, *)
    private func configureContinuedTask(task: BGTask) {
        logger.info("🔁 Continued processing task handler configured")

        stateQueue.sync {
            self.activeTask = task
        }

        task.expirationHandler = { [weak self] in
            guard let self else { return }

            self.logger.info("⚠️ Continued processing task expired (device locked) - BGProcessingTask continues running")

            // CRITICAL: Only clean up the continued task, NOT the processing task
            // The BGProcessingTask should continue running while the device is locked
            let hasProcessingTask = self.stateQueue.sync { self.activeLongRunningTask != nil }

            if hasProcessingTask {
                // Processing task exists - let it continue, just clean up the continued task
                self.stateQueue.sync {
                    self.activeTask?.setTaskCompleted(success: false)
                    self.activeTask = nil
                }
                self.logger.info("✅ BGProcessingTask continues running in background (locked device)")
            } else {
                // No processing task - clean up everything
                self.logger.info("⚠️ No BGProcessingTask active - cancelling all handles")
                self.notifyAllHandlesOfCancellation()

                self.stateQueue.sync {
                    self.activeTask?.setTaskCompleted(success: false)
                    self.activeTask = nil
                    self.activeHandle = nil
                    self.dependentHandles.removeAll()
                }

                self.scheduleWidgetRefreshIfIdle()
            }
        }

        if let continuedTask = task as? BGContinuedProcessingTask,
           let handle = stateQueue.sync(execute: { self.activeHandle }) {
            continuedTask.progress.totalUnitCount = handle.progress.totalUnitCount
            continuedTask.progress.completedUnitCount = handle.progress.completedUnitCount
            handle.attach(taskProgress: continuedTask.progress)
            handle.notifyTaskStarted(releaseBackgroundAssertion: true)
        }
    }

    private func configureProcessingTask(task: BGProcessingTask) {
        logger.info("🔄 BGProcessingTask handler configured (works when locked)")

        stateQueue.sync {
            self.activeLongRunningTask = task
        }

        task.expirationHandler = { [weak self] in
            guard let self else { return }

            self.logger.warning("⚠️ BGProcessingTask expired")
            self.notifyAllHandlesOfCancellation()

            self.stateQueue.sync {
                self.activeLongRunningTask?.setTaskCompleted(success: false)
                self.activeLongRunningTask = nil
                self.activeHandle = nil
                self.dependentHandles.removeAll()
            }

            self.scheduleWidgetRefreshIfIdle()
        }

        if let handle = stateQueue.sync(execute: { self.activeHandle }) {
            handle.notifyTaskStarted(releaseBackgroundAssertion: true)
        }
    }

    private func configureRefreshTask(task: BGAppRefreshTask) {
        logger.info("🔄 BGAppRefreshTask fired for widget refresh")

        let canRun = stateQueue.sync { self.activeHandle == nil && self.dependentHandles.isEmpty }

        guard canRun else {
            logger.info("ℹ️ Skipping widget refresh because Gemini tasks are active")
            task.setTaskCompleted(success: false)
            scheduleWidgetRefreshIfIdle()
            return
        }

        let refreshWork = Task(priority: .utility) {
            let success = await self.performLatestNewsBackgroundRefresh()

            if Task.isCancelled { return }

            task.setTaskCompleted(success: success)
            self.scheduleWidgetRefreshIfIdle()
        }

        task.expirationHandler = { [weak self] in
            guard let self else { return }
            self.logger.info("⚠️ BGAppRefreshTask expired before completion")
            refreshWork.cancel()
            task.setTaskCompleted(success: false)
            self.scheduleWidgetRefreshIfIdle(after: self.widgetRefreshInterval / 2)
        }
    }

    @available(iOS 26.0, *)
    private func submitContinuedRequest(title: String, subtitle: String) throws {
        let identifier = continuedTaskIdentifier
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
        logger.info("✅ Submitted continued processing task request")
    }

    private func submitProcessingRequest(identifier: String, title: String) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date()

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("✅ Submitted BGProcessingTask '\(identifier)'")
        } catch {
            logger.error("❌ Failed to submit BGProcessingTask: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Schedule a widget refresh, deferring until Gemini work is idle.
    func scheduleWidgetRefreshIfIdle(after interval: TimeInterval? = nil) {
        stateQueue.async {
            let hasActive = self.activeHandle != nil || !self.dependentHandles.isEmpty
            if hasActive {
                self.pendingWidgetRefresh = true
                self.logger.info("ℹ️ Deferring widget refresh scheduling while Gemini tasks are active")
                return
            }

            let delay = interval ?? self.widgetRefreshInterval
            self.identifiers(for: .refresh).forEach {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0)
            }

            let request = BGAppRefreshTaskRequest(identifier: self.refreshTaskIdentifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: delay)

            do {
                try BGTaskScheduler.shared.submit(request)
                self.pendingWidgetRefresh = false
                self.logger.info("✅ Scheduled widget refresh task (~\(Int(delay / 60)) min)")
            } catch {
                self.logger.error("❌ Failed to schedule widget refresh: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func performLatestNewsBackgroundRefresh() async -> Bool {
        guard #available(iOS 14.0, *) else {
            logger.info("ℹ️ Widget refresh requires iOS 14+; skipping")
            return false
        }

        let canRun = stateQueue.sync { self.activeHandle == nil && self.dependentHandles.isEmpty }
        guard canRun else {
            logger.info("ℹ️ Gemini work started before refresh; aborting widget refresh")
            stateQueue.async { self.pendingWidgetRefresh = true }
            return false
        }

        if Task.isCancelled { return false }

        let persistence = PersistenceManager.shared
        let subscriptions = persistence.loadSubscriptions()
        let rssSubscriptions = subscriptions.filter { $0.type == .rss }
        let redditSubscriptions = subscriptions.filter { $0.type == .reddit }

        if rssSubscriptions.isEmpty && redditSubscriptions.isEmpty {
            logger.info("ℹ️ No subscriptions available for background refresh")
            return false
        }

        let feedService = FeedService()
        // Create RedditService with OAuth manager for automatic token refresh
        let redditOAuthManager = RedditOAuthManager()
        let redditService = RedditService(oauthManager: redditOAuthManager)
        var cancellables = Set<AnyCancellable>()
        let group = DispatchGroup()
        let aggregationQueue = DispatchQueue(label: "com.joaovalente.rssreader.latestnews.background", qos: .utility)

        var feeds: [Feed] = []
        var redditFeeds: [RedditFeed] = []

        for subscription in rssSubscriptions {
            group.enter()
            feedService.fetchFeed(url: subscription.url)
                .sink { feed in
                    aggregationQueue.async {
                        var processedFeed = feed
                        for index in processedFeed.articles.indices {
                            let articleId = processedFeed.articles[index].id
                            processedFeed.articles[index].isRead = persistence.isArticleRead(processedFeed.articles[index])
                            processedFeed.articles[index].isFavorite = persistence.isArticleFavorite(articleId)
                        }
                        feeds.append(processedFeed)
                        group.leave()
                    }
                }
                .store(in: &cancellables)
        }

        for subscription in redditSubscriptions {
            group.enter()
            redditService.fetchSubreddit(subreddit: subscription.url, sortOption: .hot)
                .sink { redditFeed in
                    aggregationQueue.async {
                        var processedFeed = redditFeed
                        for index in processedFeed.posts.indices {
                            let postId = processedFeed.posts[index].id
                            processedFeed.posts[index].isRead = persistence.isRedditPostRead(processedFeed.posts[index])
                            processedFeed.posts[index].isFavorite = persistence.isRedditPostFavorite(postId)
                        }
                        redditFeeds.append(processedFeed)
                        group.leave()
                    }
                }
                .store(in: &cancellables)
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<([Feed], [RedditFeed]), Never>) in
            group.notify(queue: aggregationQueue) {
                continuation.resume(returning: (feeds, redditFeeds))
            }
        }

        cancellables.removeAll()

        if Task.isCancelled { return false }

        guard let snapshot = await LatestNewsSnapshotBuilder.buildSnapshot(fromFeeds: result.0, redditFeeds: result.1) else {
            logger.info("ℹ️ Background refresh produced no latest-news items")
            return false
        }

        if Task.isCancelled { return false }

        await MainActor.run {
            LatestNewsStore.shared.save(snapshot)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: "LatestNewsWidget")
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }

        logger.info("✅ Latest-news snapshot refreshed in background with \(snapshot.items.count) items")
        return true
    }

    fileprivate func complete(_ handle: GeminiBackgroundTaskHandle, success: Bool) {
        stateQueue.sync {
            guard self.activeHandle === handle else {
                self.logger.info("Ignoring completion for non-root Gemini handle")
                return
            }

            self.activeTask?.setTaskCompleted(success: success)
            self.activeLongRunningTask?.setTaskCompleted(success: success)

            self.activeTask = nil
            self.activeLongRunningTask = nil
            self.activeHandle = nil
            self.dependentHandles.removeAll()
        }

        logger.info("✅ Gemini background task finished (success = \(success ? "true" : "false"))")
        scheduleWidgetRefreshIfIdle()
    }

    fileprivate func completeDependent(_ handle: GeminiBackgroundTaskHandle, success: Bool) {
        stateQueue.sync {
            self.dependentHandles.removeValue(forKey: ObjectIdentifier(handle))
        }
        logger.info("✅ Gemini dependent task finished (success = \(success ? "true" : "false"))")
        scheduleWidgetRefreshIfIdle()
    }

    /// Cancel all pending background work.
    func cancelAllPendingTasks() {
        notifyAllHandlesOfCancellation()
        self.identifiers(for: .continued).forEach {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0)
        }
        self.identifiers(for: .processing).forEach {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0)
        }
        self.identifiers(for: .summarization).forEach {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0)
        }
        self.identifiers(for: .refresh).forEach {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0)
        }

        stateQueue.sync {
            activeHandle = nil
            dependentHandles.removeAll()
            activeTask = nil
            activeLongRunningTask = nil
            pendingWidgetRefresh = false
        }

        logger.info("🚫 Cancelled all pending background tasks")
    }

    private func handlesSnapshot() -> [GeminiBackgroundTaskHandle] {
        stateQueue.sync {
            var handles: [GeminiBackgroundTaskHandle] = []
            if let root = self.activeHandle {
                handles.append(root)
            }
            handles.append(contentsOf: self.dependentHandles.values)
            return handles
        }
    }

    private func notifyAllHandlesOfCancellation() {
        handlesSnapshot().forEach { $0.notifyCancellation() }
    }
}

/// Handle object for tracking an in-flight Gemini task.
final class GeminiBackgroundTaskHandle {
    fileprivate let progress: Progress
    private weak var manager: GeminiBackgroundTaskManager?
    private let stateLock = NSLock()

    private var taskProgress: Progress?
    private var cancellationHandlers: [() -> Void] = []
    private(set) var isCancelled = false
    private var finished = false
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var started = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var requiresSystemSignal = false
    private var backgroundReleaseWorkItem: DispatchWorkItem?

    fileprivate let isRootHandle: Bool
    var taskIdentifier: String?
    var onTaskStarted: (() -> Void)?

    fileprivate init(manager: GeminiBackgroundTaskManager, totalUnitCount: Int64, isRootHandle: Bool) {
        self.manager = manager
        self.progress = Progress(totalUnitCount: totalUnitCount)
        self.isRootHandle = isRootHandle
        beginBackgroundAssertion()
    }

    func reportProgress(fractionCompleted fraction: Double) {
        stateLock.lock()
        let clampedFraction = max(0, min(1, fraction))
        progress.completedUnitCount = Int64(Double(progress.totalUnitCount) * clampedFraction)
        taskProgress?.completedUnitCount = progress.completedUnitCount
        stateLock.unlock()
    }

    func reportProgress(completedUnitCount: Int64) {
        stateLock.lock()
        let clamped = max(0, min(completedUnitCount, progress.totalUnitCount))
        progress.completedUnitCount = clamped
        taskProgress?.completedUnitCount = clamped
        stateLock.unlock()
    }

    func registerCancellationHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        cancellationHandlers.append(handler)
        let shouldCallImmediately = isCancelled
        stateLock.unlock()

        if shouldCallImmediately {
            handler()
        }
    }

    fileprivate func setRequiresSystemSignal(_ value: Bool) {
        stateLock.lock()
        requiresSystemSignal = value
        stateLock.unlock()
    }

    fileprivate func notifyCancellation() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            return
        }
        isCancelled = true
        let handlers = cancellationHandlers
        stateLock.unlock()

        handlers.forEach { $0() }
        resumePendingStartContinuation()
        endBackgroundAssertionIfNeeded()
    }

    var cancelled: Bool {
        stateLock.lock()
        let value = isCancelled
        stateLock.unlock()
        return value
    }

    func waitForTaskStartIfNeeded() async {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            stateLock.lock()
            let shouldWait = requiresSystemSignal && !started
            stateLock.unlock()

            guard shouldWait else { return }

            await withCheckedContinuation { continuation in
                stateLock.lock()
                if started || !requiresSystemSignal {
                    stateLock.unlock()
                    continuation.resume()
                    return
                }
                startContinuation = continuation
                stateLock.unlock()
            }
        }
        #endif
    }

    func finish(success: Bool) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        taskProgress = nil
        stateLock.unlock()

        if isRootHandle {
            manager?.complete(self, success: success)
        } else {
            manager?.completeDependent(self, success: success)
        }
        endBackgroundAssertionIfNeeded()
    }

    fileprivate func attach(taskProgress: Progress) {
        stateLock.lock()
        taskProgress.totalUnitCount = progress.totalUnitCount
        taskProgress.completedUnitCount = progress.completedUnitCount
        self.taskProgress = taskProgress
        stateLock.unlock()
    }

    fileprivate func notifyTaskStarted(releaseBackgroundAssertion: Bool = false) {
        var continuation: CheckedContinuation<Void, Never>?
        var shouldInvokeCallback = false
        var callback: (() -> Void)?
        let shouldReleaseAssertion = releaseBackgroundAssertion

        stateLock.lock()
        if !started {
            started = true
            requiresSystemSignal = false
            continuation = startContinuation
            startContinuation = nil
            shouldInvokeCallback = true
        }
        callback = onTaskStarted
        stateLock.unlock()

        continuation?.resume()

        if shouldInvokeCallback {
            callback?()
        }

        if shouldReleaseAssertion {
            endBackgroundAssertionIfNeeded()
        }
    }

    private func beginBackgroundAssertion() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.stateLock.lock()
            let alreadyActive = self.backgroundTaskIdentifier != .invalid
            self.stateLock.unlock()

            guard !alreadyActive else { return }

            let identifier = UIApplication.shared.beginBackgroundTask(withName: "GeminiSummary") { [weak self] in
                self?.handleBackgroundTaskExpiration()
            }

            self.stateLock.lock()
            self.backgroundTaskIdentifier = identifier
            self.stateLock.unlock()

            self.scheduleBackgroundAssertionReleaseIfNeeded()
        }
    }

    private func handleBackgroundTaskExpiration() {
        notifyCancellation()
        endBackgroundAssertionIfNeeded()
    }

    private func endBackgroundAssertionIfNeeded() {
        let identifier: UIBackgroundTaskIdentifier
        stateLock.lock()
        identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        stateLock.unlock()

        guard identifier != .invalid else { return }

        backgroundReleaseWorkItem?.cancel()
        backgroundReleaseWorkItem = nil

        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func resumePendingStartContinuation() {
        var continuation: CheckedContinuation<Void, Never>?

        stateLock.lock()
        continuation = startContinuation
        startContinuation = nil
        requiresSystemSignal = false
        stateLock.unlock()

        continuation?.resume()
    }

    func applicationDidEnterBackground() {
        scheduleBackgroundAssertionReleaseIfNeeded()
    }

    func applicationWillEnterForeground() {
        stateLock.lock()
        let shouldCancel = backgroundReleaseWorkItem != nil
        stateLock.unlock()

        guard shouldCancel else { return }

        backgroundReleaseWorkItem?.cancel()
        backgroundReleaseWorkItem = nil
    }

    private func scheduleBackgroundAssertionReleaseIfNeeded() {
        stateLock.lock()
        let identifier = backgroundTaskIdentifier
        stateLock.unlock()

        guard identifier != .invalid else { return }
        guard UIApplication.shared.applicationState != .active else { return }

        backgroundReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endBackgroundAssertionIfNeeded()
        }
        backgroundReleaseWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
    }
}
#endif
