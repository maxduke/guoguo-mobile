import Foundation

/// Intent survives AVQueuePlayer's transient zero rate and empty queue at EOF.
/// Media objects and confirmed position remain owned by the native session.
struct AirPlayQueueState {
    enum AppendResult: Equatable { case duplicate, queued, advance, stale, full }
    private(set) var currentID: String
    private(set) var nextID: String?
    private(set) var outgoingIDs: Set<String> = []
    private(set) var ended = false
    private(set) var advanceRequested = false
    private(set) var knownIDs: Set<String>
    var wantsPlayback: Bool

    init(id: String, playing: Bool) {
        currentID = id
        wantsPlayback = playing
        knownIDs = [id]
    }

    mutating func append(id: String, after predecessor: String) -> AppendResult {
        if knownIDs.contains(id) { return .duplicate }
        guard predecessor == currentID else { return .stale }
        guard nextID == nil else { return .full }
        knownIDs.insert(id)
        nextID = id
        return advanceRequested ? .advance : .queued
    }

    @discardableResult
    mutating func becameCurrent(_ id: String) -> Bool {
        guard id == nextID else { return id == currentID }
        outgoingIDs.insert(currentID)
        currentID = id
        nextID = nil
        ended = false
        advanceRequested = false
        return true
    }

    @discardableResult
    mutating func finished(_ id: String) -> Bool {
        guard id == currentID, !ended else { return false }
        ended = true
        return true
    }

    /// Failed queued items must leave both the slot and deduplication set so
    /// a retry with the same episode ID can install a fresh native item.
    mutating func rejectNext(_ id: String) -> Bool {
        guard nextID == id else { return false }
        nextID = nil
        knownIDs.remove(id)
        return true
    }

    mutating func confirmedPlayback(_ id: String, advanced: Bool) {
        guard id == currentID, advanced else { return }
        outgoingIDs.removeAll()
    }

    mutating func retryCurrent(playing: Bool) {
        // Retry has explicitly detached the entire preceding player.
        outgoingIDs.removeAll()
        ended = false
        wantsPlayback = playing
    }

    mutating func requestNext() {
        advanceRequested = true
    }

    var needsNext: Bool { nextID == nil }
}

/// Never serialize localizedDescription/userInfo: native errors can contain
/// relay tokens, signed provider URLs, headers and encryption keys.
enum AirPlayFailure {
    static func code(_ error: NSError?) -> String {
        guard let error else { return "unknown" }
        let domains = [NSURLErrorDomain: "url", "AVFoundationErrorDomain": "av",
                       NSOSStatusErrorDomain: "os", "CoreMediaErrorDomain": "media"]
        let code = "\(domains[error.domain] ?? "native"):\(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return code + "/\(domains[underlying.domain] ?? "native"):\(underlying.code)"
        }
        return code
    }
}
