import Foundation

/// Intent survives AVQueuePlayer's transient zero rate and empty queue at EOF.
/// Media objects and confirmed position remain owned by the native session.
struct AirPlayQueueState {
    enum AppendResult: Equatable { case duplicate, queued, advance, stale, full }
    private(set) var currentID: String
    private(set) var nextID: String?
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

    mutating func requestNext() {
        advanceRequested = true
    }

    var needsNext: Bool { nextID == nil }
}
