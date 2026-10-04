import Foundation

@main
struct PlayerPolicyTests {
    static func main() {
        let cases: [(String?, String, Bool)] = [
            ("hls", "http://127.0.0.1:1234/token/index.m3u8", false),
            ("hls", "https://example.test/media?id=1", false),
            (nil, "https://example.test/video.M3U8?token=1", false),
            (nil, "file:///tmp/index.m3u8", false),
            ("HLS", "https://example.test/opaque", false),
            (nil, "file:///tmp/complete.mp4", true),
            (nil, "https://example.test/video.mp4", true),
            (nil, "https://example.test/m3u8/video.mp4", true),
        ]
        for (hint, address, expected) in cases {
            let actual = GuoguoMediaPolicy.allowsVideoComposition(formatHint: hint, url: URL(string: address)!)
            precondition(actual == expected, "Unexpected composition policy for \(address)")
        }
        for (owned, routed, held) in [(false, false, false), (true, false, true), (false, true, true), (true, true, true)] {
            precondition(GuoguoMediaPolicy.shouldHoldLocalPlayback(airPlaySessionActive: owned, routed: routed) == held)
        }
        // EOF can precede preparation of the successor. Its transient native
        // zero rate must not erase playback intent or replay the previous item.
        var late = AirPlayQueueState(id: "a", playing: true)
        precondition(late.finished("a"))
        precondition(late.ended && late.needsNext && late.wantsPlayback)
        precondition(late.append(id: "b", after: "a") == .queued)
        precondition(late.becameCurrent("b"))
        precondition(!late.ended && late.wantsPlayback && late.currentID == "b")
        precondition(!late.finished("a")) // Late notification cannot end b.
        precondition(late.append(id: "b", after: "a") == .duplicate)
        precondition(late.append(id: "a", after: "a") == .duplicate)
        precondition(late.append(id: "c", after: "a") == .stale)
        precondition(late.append(id: "c", after: "b") == .queued)
        precondition(late.append(id: "d", after: "b") == .full)
        precondition(late.nextID == "c" && !late.knownIDs.contains("d"))

        // KVO may announce the successor before the preceding end notification.
        var early = AirPlayQueueState(id: "a", playing: true)
        precondition(early.append(id: "b", after: "a") == .queued)
        precondition(early.becameCurrent("b"))
        precondition(!early.finished("a") && !early.ended && early.wantsPlayback)
        precondition(early.finished("b"))
        precondition(!early.finished("b")) // Completion is idempotent.

        // A viewer pause remains a pause across EOF and a late queued item.
        var paused = AirPlayQueueState(id: "a", playing: false)
        precondition(paused.finished("a"))
        precondition(paused.append(id: "b", after: "a") == .queued)
        precondition(paused.becameCurrent("b") && !paused.wantsPlayback)

        // Explicit Next overrides the absence of automatic prefetch; its pending
        // advance survives a failed preparation/retry and duplicate requests.
        var manual = AirPlayQueueState(id: "a", playing: true)
        manual.requestNext()
        manual.requestNext()
        precondition(manual.advanceRequested && manual.needsNext)
        precondition(manual.append(id: "b", after: "a") == .advance)
        precondition(manual.becameCurrent("b"))
        precondition(!manual.advanceRequested && manual.wantsPlayback)
        precondition(!manual.becameCurrent("unknown") && manual.currentID == "b")
        print("Player HLS policy: \(cases.count) cases; native AirPlay queue races passed")
    }
}
