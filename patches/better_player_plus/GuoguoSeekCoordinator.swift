import Foundation

public enum GuoguoSeekResult: Equatable {
    case completed, cancelled, failed, timedOut
}

/// Main-thread coordinator: finish the in-flight AVPlayer seek, then chase only
/// the latest target. Superseded callers complete once without resuming playback.
final class GuoguoSeekCoordinator {
    typealias Schedule = (@escaping () -> Void) -> (() -> Void)
    private final class Request {
        let id: Int
        let perform: (@escaping (Bool) -> Void) -> Void
        let cancel: () -> Void
        private var completion: ((GuoguoSeekResult) -> Void)?
        init(id: Int, perform: @escaping (@escaping (Bool) -> Void) -> Void,
             cancel: @escaping () -> Void, completion: @escaping (GuoguoSeekResult) -> Void) {
            self.id = id; self.perform = perform; self.cancel = cancel; self.completion = completion
        }
        func finish(_ result: GuoguoSeekResult) {
            let callback = completion
            completion = nil
            callback?(result)
        }
    }
    private let schedule: Schedule
    private var serial = 0
    private var active: Request?
    private var pending: Request?
    private var cancelTimeout: (() -> Void)?
    var isSeeking: Bool { active != nil }

    init(schedule: @escaping Schedule = { action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        return { work.cancel() }
    }) { self.schedule = schedule }

    func seek(perform: @escaping (@escaping (Bool) -> Void) -> Void,
              cancel: @escaping () -> Void, completion: @escaping (GuoguoSeekResult) -> Void) {
        serial += 1
        let request = Request(id: serial, perform: perform, cancel: cancel, completion: completion)
        if let active {
            let replaced = pending
            pending = request
            active.finish(.cancelled)
            replaced?.finish(.cancelled)
        } else { start(request) }
    }

    func invalidate(_ result: GuoguoSeekResult = .cancelled) {
        let old = active, queued = pending
        active = nil; pending = nil
        cancelTimeout?(); cancelTimeout = nil
        // State is invalidated before native cancellation can invoke its callback.
        old?.cancel()
        old?.finish(result)
        queued?.finish(result)
    }

    private func start(_ request: Request) {
        active = request
        let id = request.id
        cancelTimeout = schedule { [weak self] in
            guard let self, self.active?.id == id else { return }
            self.invalidate(.timedOut)
        }
        request.perform { [weak self] finished in
            guard let self, self.active?.id == request.id else { return }
            self.cancelTimeout?(); self.cancelTimeout = nil
            self.active = nil
            let next = self.pending
            self.pending = nil
            if let next { self.start(next) }
            request.finish(finished ? .completed : .failed)
        }
    }
}
