import Foundation

@main
struct PlayerSeekTests {
    static func main() {
        var deadlines: [() -> Void] = []
        var cancelledTimers = 0
        let seeks = GuoguoSeekCoordinator(schedule: { action in
            deadlines.append(action)
            return { cancelledTimers += 1 }
        })
        var started: [Int] = [], cancelledNative = 0
        var callbacks: [Int: (Bool) -> Void] = [:]
        var outcomes: [Int: [GuoguoSeekResult]] = [:]
        func request(_ target: Int) {
            seeks.seek(perform: { done in
                started.append(target)
                callbacks[target] = done
            }, cancel: { cancelledNative += 1 }, completion: { result in
                outcomes[target, default: []].append(result)
            })
        }
        // Rapid drags do not cancel/restart AVPlayer repeatedly. Intermediate
        // callers complete as cancelled; only the last target reaches the engine.
        request(1); request(2); request(3)
        precondition(started == [1] && seeks.isSeeking)
        precondition(outcomes[1] == [.cancelled] && outcomes[2] == [.cancelled])
        callbacks[1]!(true)
        precondition(started == [1, 3] && seeks.isSeeking)
        precondition(outcomes[3] == nil && cancelledNative == 0)
        callbacks[3]!(true)
        precondition(!seeks.isSeeking && outcomes[3] == [.completed])
        callbacks[1]!(false) // Stale/duplicate native completions are inert.
        precondition(outcomes[1] == [.cancelled] && outcomes[3] == [.completed])

        // Source replacement/disposal cancels active and pending requests once,
        // and a late completion cannot affect the replacement source.
        request(4); request(5)
        seeks.invalidate()
        request(6)
        callbacks[4]!(true)
        precondition(started == [1, 3, 4, 6] && seeks.isSeeking)
        precondition(outcomes[4] == [.cancelled] && outcomes[5] == [.cancelled])
        callbacks[6]!(false)
        precondition(outcomes[6] == [.failed] && !seeks.isSeeking)

        // Missing native completions have a finite lifetime, including the last
        // queued caller. Cancellation is invalidated before a reentrant callback.
        request(7); request(8)
        deadlines.last!()
        precondition(!seeks.isSeeking && outcomes[8] == [.timedOut])
        callbacks[7]!(true)
        precondition(outcomes[7] == [.cancelled] && outcomes[8] == [.timedOut])
        request(9)
        deadlines[0]() // An old deadline cannot timeout a new seek.
        precondition(seeks.isSeeking)
        callbacks[9]!(true)
        precondition(outcomes[9] == [.completed] && !seeks.isSeeking)
        precondition(cancelledNative == 2 && cancelledTimers == 6)

        var reentrant: ((Bool) -> Void)?
        var reentrantOutcome: [GuoguoSeekResult] = []
        seeks.seek(perform: { reentrant = $0 }, cancel: { reentrant?(true) }, completion: {
            reentrantOutcome.append($0)
        })
        seeks.invalidate()
        precondition(reentrantOutcome == [.cancelled] && !seeks.isSeeking)
        print("Native seek queue: latest target, cancellation, timeout and stale callbacks passed")
    }
}
