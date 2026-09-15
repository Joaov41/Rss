#if os(iOS)
import Foundation
import BackgroundTasks
import OSLog
import UIKit

struct PodcastBackgroundSessionLifecycle: Equatable {
    private(set) var rootFinished = false
    private(set) var succeeded = true

    mutating func reset() {
        rootFinished = false
        succeeded = true
    }

    mutating func recordRootCompletion(success: Bool, hasDependents: Bool) -> Bool {
        rootFinished = true
        succeeded = succeeded && success
        return !hasDependents
    }

    mutating func recordDependentCompletion(success: Bool, hasRemainingDependents: Bool) -> Bool {
        succeeded = succeeded && success
        return rootFinished && !hasRemainingDependents
    }
}

/// Background execution dedicated to podcast transcript preparation and
/// transcript-grounded AI work. It intentionally has no shared state or task
/// identifiers with the app's existing Gemini/background-refresh manager.
final class PodcastBackgroundTaskManager {
    static let shared = PodcastBackgroundTaskManager()

    private let logger = Logger(subsystem: "com.joaovalente.rssreader", category: "PodcastBackgroundTask")
    private let stateQueue = DispatchQueue(label: "com.joaovalente.rssreader.podcastBackgroundTask.state")

    private let bundleIdentifierPrefix: String = {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            return "com.joaovalente.rssreader"
        }
        return identifier
    }()
    private let legacyBundleIdentifierPrefix = "com.joaovalente.rssreader"

    private lazy var continuedTaskIdentifier = "\(bundleIdentifierPrefix).podcastTask"
    private lazy var processingTaskIdentifier = "\(bundleIdentifierPrefix).podcastProcessing"
    private var legacyContinuedTaskIdentifier: String { "\(legacyBundleIdentifierPrefix).podcastTask" }
    private var legacyProcessingTaskIdentifier: String { "\(legacyBundleIdentifierPrefix).podcastProcessing" }

    private var isRegistered = false
    private var activeHandle: PodcastBackgroundTaskHandle?
    private var dependentHandles: [ObjectIdentifier: PodcastBackgroundTaskHandle] = [:]
    private var lifecycle = PodcastBackgroundSessionLifecycle()
    private var activeContinuedTask: BGTask?
    private var activeProcessingTask: BGProcessingTask?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private init() {}

    func prepareForLaunch() {
        registerHandlers()
        registerLifecycleObservers()
    }

    func beginTask(title: String) -> PodcastBackgroundTaskHandle {
        registerHandlers()

        let handle: PodcastBackgroundTaskHandle = stateQueue.sync {
            let isRoot = activeHandle == nil
            let handle = PodcastBackgroundTaskHandle(manager: self, isRootHandle: isRoot)
            if isRoot {
                lifecycle.reset()
                activeHandle = handle
            } else {
                dependentHandles[ObjectIdentifier(handle)] = handle
            }
            return handle
        }

        if handle.isRootHandle {
            if #available(iOS 26.0, *) {
                handle.setRequiresSystemSignal(true)
                do {
                    try submitContinuedRequest(title: title)
                    submitProcessingRequest()
                    handle.notifyTaskStarted()
                    logger.info("Submitted isolated podcast background work: \(title, privacy: .public)")
                } catch {
                    handle.setRequiresSystemSignal(false)
                    handle.notifyTaskStarted()
                    logger.error("Could not submit podcast continued-processing task: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                handle.notifyTaskStarted()
            }
        } else {
            handle.notifyTaskStarted()
            logger.info("Attached podcast work to the active podcast-only background session")
        }

        return handle
    }

    private var continuedIdentifiers: [String] {
        continuedTaskIdentifier == legacyContinuedTaskIdentifier
            ? [continuedTaskIdentifier]
            : [continuedTaskIdentifier, legacyContinuedTaskIdentifier]
    }

    private var processingIdentifiers: [String] {
        processingTaskIdentifier == legacyProcessingTaskIdentifier
            ? [processingTaskIdentifier]
            : [processingTaskIdentifier, legacyProcessingTaskIdentifier]
    }

    private func registerHandlers() {
        guard !isRegistered else { return }

        if #available(iOS 26.0, *) {
            continuedIdentifiers.forEach { identifier in
                BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                    self?.configureContinuedTask(task)
                }
            }
        }

        processingIdentifiers.forEach { identifier in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
                guard let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.configureProcessingTask(processingTask)
            }
        }

        isRegistered = true
    }

    private func registerLifecycleObservers() {
        guard backgroundObserver == nil else { return }

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlesSnapshot().forEach { $0.applicationDidEnterBackground() }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handlesSnapshot().forEach { $0.applicationWillEnterForeground() }
        }
    }

    @available(iOS 26.0, *)
    private func submitContinuedRequest(title: String) throws {
        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedTaskIdentifier,
            title: title,
            subtitle: "Preparing the episode transcript"
        )
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }

    private func submitProcessingRequest() {
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.error("Could not submit podcast BGProcessingTask: \(error.localizedDescription, privacy: .public)")
        }
    }

    @available(iOS 26.0, *)
    private func configureContinuedTask(_ task: BGTask) {
        let configuration: (representative: PodcastBackgroundTaskHandle, root: PodcastBackgroundTaskHandle)? = stateQueue.sync {
            guard let root = activeHandle,
                  let representative = representativeHandleLocked() else { return nil }
            if let previousTask = activeContinuedTask, previousTask !== task {
                previousTask.setTaskCompleted(success: false)
            }
            activeContinuedTask = task
            return (representative, root)
        }

        guard let configuration else {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak self, weak task, weak root = configuration.root] in
            guard let self, let task, let root else { return }
            self.expireContinuedTask(task, expectedRoot: root)
        }

        if let continuedTask = task as? BGContinuedProcessingTask {
            continuedTask.progress.totalUnitCount = configuration.representative.progress.totalUnitCount
            continuedTask.progress.completedUnitCount = configuration.representative.progress.completedUnitCount
            configuration.representative.attach(taskProgress: continuedTask.progress)
            configuration.representative.notifyTaskStarted(releaseBackgroundAssertion: true)
        }
    }

    private func configureProcessingTask(_ task: BGProcessingTask) {
        let configuration: (representative: PodcastBackgroundTaskHandle, root: PodcastBackgroundTaskHandle)? = stateQueue.sync {
            guard let root = activeHandle,
                  let representative = representativeHandleLocked() else { return nil }
            if let previousTask = activeProcessingTask, previousTask !== task {
                previousTask.setTaskCompleted(success: false)
            }
            activeProcessingTask = task
            return (representative, root)
        }

        guard let configuration else {
            task.setTaskCompleted(success: false)
            return
        }

        task.expirationHandler = { [weak self, weak task, weak root = configuration.root] in
            guard let self, let task, let root else { return }
            self.cancelActiveSession(expectedRoot: root, expectedProcessingTask: task)
        }
        configuration.representative.notifyTaskStarted(releaseBackgroundAssertion: true)
    }

    fileprivate func complete(_ handle: PodcastBackgroundTaskHandle, success: Bool) {
        var finalSuccess: Bool?
        stateQueue.sync {
            guard activeHandle === handle else { return }
            if lifecycle.recordRootCompletion(success: success, hasDependents: !dependentHandles.isEmpty) {
                finalSuccess = finalizeSessionLocked()
            } else {
                attachSystemProgressToRepresentativeLocked(minimum: handle.progress.completedUnitCount)
            }
        }
        if let finalSuccess {
            logger.info("Podcast background session completed (success: \(finalSuccess))")
        }
    }

    fileprivate func completeDependent(_ handle: PodcastBackgroundTaskHandle, success: Bool) {
        var finalSuccess: Bool?
        stateQueue.sync {
            guard dependentHandles.removeValue(forKey: ObjectIdentifier(handle)) != nil else { return }
            if lifecycle.recordDependentCompletion(
                success: success,
                hasRemainingDependents: !dependentHandles.isEmpty
            ) {
                finalSuccess = finalizeSessionLocked()
            } else if lifecycle.rootFinished {
                attachSystemProgressToRepresentativeLocked(minimum: handle.progress.completedUnitCount)
            }
        }
        if let finalSuccess {
            logger.info("Podcast background session completed after dependent work (success: \(finalSuccess))")
        }
    }

    private func representativeHandleLocked() -> PodcastBackgroundTaskHandle? {
        if lifecycle.rootFinished, let dependent = dependentHandles.values.first {
            return dependent
        }
        return activeHandle
    }

    private func attachSystemProgressToRepresentativeLocked(minimum: Int64) {
        guard #available(iOS 26.0, *),
              let continuedTask = activeContinuedTask as? BGContinuedProcessingTask,
              let representative = representativeHandleLocked() else { return }
        representative.reportProgress(completedUnitCount: minimum)
        representative.attach(taskProgress: continuedTask.progress)
        representative.notifyTaskStarted(releaseBackgroundAssertion: true)
    }

    private func finalizeSessionLocked() -> Bool {
        let success = lifecycle.succeeded
        activeContinuedTask?.setTaskCompleted(success: success)
        activeProcessingTask?.setTaskCompleted(success: success)
        continuedIdentifiers.forEach { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) }
        processingIdentifiers.forEach { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) }
        activeContinuedTask = nil
        activeProcessingTask = nil
        activeHandle = nil
        dependentHandles.removeAll()
        lifecycle.reset()
        return success
    }

    @available(iOS 26.0, *)
    private func expireContinuedTask(
        _ task: BGTask,
        expectedRoot: PodcastBackgroundTaskHandle
    ) {
        let cancelledHandles: [PodcastBackgroundTaskHandle]? = stateQueue.sync {
            guard activeHandle === expectedRoot,
                  activeContinuedTask === task else { return nil }

            if activeProcessingTask != nil {
                task.setTaskCompleted(success: false)
                activeContinuedTask = nil
                return []
            }

            return detachActiveSessionLocked(
                expectedRoot: expectedRoot,
                expectedContinuedTask: task
            )
        }
        cancelledHandles?.forEach { $0.notifyCancellation() }
    }

    private func cancelActiveSession(
        expectedRoot: PodcastBackgroundTaskHandle,
        expectedProcessingTask: BGProcessingTask
    ) {
        let cancelledHandles = stateQueue.sync {
            detachActiveSessionLocked(
                expectedRoot: expectedRoot,
                expectedProcessingTask: expectedProcessingTask
            )
        }
        cancelledHandles?.forEach { $0.notifyCancellation() }
    }

    private func detachActiveSessionLocked(
        expectedRoot: PodcastBackgroundTaskHandle,
        expectedContinuedTask: BGTask? = nil,
        expectedProcessingTask: BGProcessingTask? = nil
    ) -> [PodcastBackgroundTaskHandle]? {
        guard activeHandle === expectedRoot else { return nil }
        if let expectedContinuedTask,
           activeContinuedTask !== expectedContinuedTask { return nil }
        if let expectedProcessingTask,
           activeProcessingTask !== expectedProcessingTask { return nil }

        var handles = Array(dependentHandles.values)
        handles.append(expectedRoot)
        activeContinuedTask?.setTaskCompleted(success: false)
        activeProcessingTask?.setTaskCompleted(success: false)
        continuedIdentifiers.forEach { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) }
        processingIdentifiers.forEach { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: $0) }
        activeContinuedTask = nil
        activeProcessingTask = nil
        activeHandle = nil
        dependentHandles.removeAll()
        lifecycle.reset()
        return handles
    }

    private func handlesSnapshot() -> [PodcastBackgroundTaskHandle] {
        stateQueue.sync {
            var handles = Array(dependentHandles.values)
            if let activeHandle { handles.append(activeHandle) }
            return handles
        }
    }
}

final class PodcastBackgroundTaskHandle {
    fileprivate let progress = Progress(totalUnitCount: 100)
    fileprivate let isRootHandle: Bool

    private weak var manager: PodcastBackgroundTaskManager?
    private let stateLock = NSLock()
    private var taskProgress: Progress?
    private var cancellationHandlers: [() -> Void] = []
    private var isCancelled = false
    private var finished = false
    private var started = false
    private var requiresSystemSignal = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var backgroundReleaseWorkItem: DispatchWorkItem?

    fileprivate init(manager: PodcastBackgroundTaskManager, isRootHandle: Bool) {
        self.manager = manager
        self.isRootHandle = isRootHandle
        beginBackgroundAssertion()
    }

    var cancelled: Bool {
        stateLock.withLock { isCancelled }
    }

    func reportProgress(fractionCompleted fraction: Double) {
        let requested = Int64(Double(progress.totalUnitCount) * max(0, min(1, fraction)))
        reportProgress(completedUnitCount: requested)
    }

    func reportProgress(completedUnitCount: Int64) {
        stateLock.lock()
        let clamped = max(0, min(completedUnitCount, progress.totalUnitCount))
        progress.completedUnitCount = max(progress.completedUnitCount, clamped)
        taskProgress?.completedUnitCount = progress.completedUnitCount
        stateLock.unlock()
    }

    func registerCancellationHandler(_ handler: @escaping () -> Void) {
        stateLock.lock()
        cancellationHandlers.append(handler)
        let callImmediately = isCancelled
        stateLock.unlock()
        if callImmediately { handler() }
    }

    func waitForTaskStartIfNeeded() async {
        guard #available(iOS 26.0, *) else { return }
        let shouldWait = stateLock.withLock { requiresSystemSignal && !started }
        guard shouldWait else { return }

        await withCheckedContinuation { continuation in
            stateLock.lock()
            if started || !requiresSystemSignal {
                stateLock.unlock()
                continuation.resume()
            } else {
                startContinuation = continuation
                stateLock.unlock()
            }
        }
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

    fileprivate func setRequiresSystemSignal(_ value: Bool) {
        stateLock.withLock { requiresSystemSignal = value }
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
        stateLock.lock()
        if !started {
            started = true
            requiresSystemSignal = false
            continuation = startContinuation
            startContinuation = nil
        }
        stateLock.unlock()
        continuation?.resume()
        if releaseBackgroundAssertion { endBackgroundAssertionIfNeeded() }
    }

    fileprivate func notifyCancellation() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            return
        }
        isCancelled = true
        let handlers = cancellationHandlers
        let continuation = startContinuation
        startContinuation = nil
        requiresSystemSignal = false
        stateLock.unlock()

        handlers.forEach { $0() }
        continuation?.resume()
        endBackgroundAssertionIfNeeded()
    }

    fileprivate func applicationDidEnterBackground() {
        scheduleBackgroundAssertionReleaseIfNeeded()
    }

    fileprivate func applicationWillEnterForeground() {
        backgroundReleaseWorkItem?.cancel()
        backgroundReleaseWorkItem = nil
    }

    private func beginBackgroundAssertion() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldStart = self.stateLock.withLock {
                self.backgroundTaskIdentifier == .invalid && !self.finished && !self.isCancelled
            }
            guard shouldStart else { return }

            let identifier = UIApplication.shared.beginBackgroundTask(withName: "PodcastTranscript") { [weak self] in
                self?.notifyCancellation()
            }
            let shouldEndImmediately = self.stateLock.withLock { () -> Bool in
                guard !self.finished, !self.isCancelled else { return true }
                self.backgroundTaskIdentifier = identifier
                return false
            }
            if shouldEndImmediately {
                UIApplication.shared.endBackgroundTask(identifier)
                return
            }
            self.scheduleBackgroundAssertionReleaseIfNeeded()
        }
    }

    private func endBackgroundAssertionIfNeeded() {
        let identifier = stateLock.withLock { () -> UIBackgroundTaskIdentifier in
            let current = backgroundTaskIdentifier
            backgroundTaskIdentifier = .invalid
            return current
        }
        guard identifier != .invalid else { return }
        backgroundReleaseWorkItem?.cancel()
        backgroundReleaseWorkItem = nil
        DispatchQueue.main.async {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }

    private func scheduleBackgroundAssertionReleaseIfNeeded() {
        let identifier = stateLock.withLock { backgroundTaskIdentifier }
        guard identifier != .invalid, UIApplication.shared.applicationState != .active else { return }
        backgroundReleaseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endBackgroundAssertionIfNeeded()
        }
        backgroundReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
#endif
