import Foundation

/// macOS counterpart to the iOS podcast background task coordinator. A
/// ProcessInfo activity keeps App Nap and automatic termination from stopping
/// transcript/AI work when the window is backgrounded, while retaining the
/// same progress, cancellation, and lease API used by AppState.
final class PodcastBackgroundTaskManager {
    static let shared = PodcastBackgroundTaskManager()

    private let lock = NSLock()
    private var activeHandles: [ObjectIdentifier: PodcastBackgroundTaskHandle] = [:]

    private init() {}

    func prepareForLaunch() {}

    func beginTask(title: String) -> PodcastBackgroundTaskHandle {
        let handle = PodcastBackgroundTaskHandle(manager: self, title: title)
        lock.lock()
        activeHandles[ObjectIdentifier(handle)] = handle
        lock.unlock()
        return handle
    }

    fileprivate func complete(_ handle: PodcastBackgroundTaskHandle) {
        lock.lock()
        activeHandles.removeValue(forKey: ObjectIdentifier(handle))
        lock.unlock()
    }
}

final class PodcastBackgroundTaskHandle {
    private weak var manager: PodcastBackgroundTaskManager?
    private let lock = NSLock()
    private let activity: NSObjectProtocol?
    private var cancellationHandlers: [() -> Void] = []
    private var isCancelled = false
    private var isFinished = false

    init(manager: PodcastBackgroundTaskManager, title: String) {
        self.manager = manager
        let reason = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Podcast processing"
            : title
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: reason
        )
    }

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return isCancelled
    }

    func reportProgress(fractionCompleted fraction: Double) {
        _ = max(0, min(1, fraction))
    }

    func registerCancellationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        cancellationHandlers.append(handler)
        let callImmediately = isCancelled
        lock.unlock()
        if callImmediately { handler() }
    }

    func waitForTaskStartIfNeeded() async {}

    func finish(success: Bool) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let currentActivity = activity
        lock.unlock()
        if let currentActivity {
            ProcessInfo.processInfo.endActivity(currentActivity)
        }
        manager?.complete(self)
    }

    func cancel() {
        lock.lock()
        guard !isCancelled, !isFinished else { lock.unlock(); return }
        isCancelled = true
        let handlers = cancellationHandlers
        lock.unlock()
        handlers.forEach { $0() }
    }
}
