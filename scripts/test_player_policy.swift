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
        for pip in [false, true] {
            for external in [false, true] {
                precondition(GuoguoMediaPolicy.shouldPauseInBackground(pipActive: pip, externalPlaybackActive: external) == (!pip && !external))
            }
        }
        let routes: [(String?, Bool)] = [
            (nil, false),
            ("file:///tmp/complete.mp4", false),
            ("http://127.0.0.1:1234/token/index.m3u8", false),
            ("http://localhost/video.mp4", false),
            ("http://[::1]/video.mp4", false),
            ("ftp://example.test/video.mp4", false),
            ("http://192.168.1.2:1234/token/0.mp4", true),
            ("https://example.test/video.m3u8", true),
        ]
        for (address, expected) in routes {
            precondition(GuoguoMediaPolicy.canUseAirPlay(url: address.flatMap { URL(string: $0) }) == expected)
        }
        let holds: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, false), // Ordinary phone file.
            (false, false, true, false),
            (false, true, true, false),
            (true, false, false, true), // Inherited TV audio + local file must wait.
            (true, false, true, true), // Relay installed; preparation still pending.
            (true, true, false, true), // Prepared intent cannot authorize a local file.
            (true, true, true, false), // Prepared first/next episode may play on TV.
        ]
        for (routed, prepared, readable, expected) in holds {
            precondition(GuoguoMediaPolicy.shouldHoldForAirPlay(routed: routed, prepared: prepared, receiverReadable: readable) == expected)
        }
        let presentations: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, false), // Local video still waits for dimensions.
            (true, true, false, true), // Track dimensions can precede presentationSize.
            (true, false, true, true), // Ready remote item must not deadlock setup.
            (true, true, true, true),
            (false, false, false, true), // Audio-only media does not need dimensions.
            (false, false, true, true),
        ]
        for (video, size, external, expected) in presentations {
            precondition(GuoguoMediaPolicy.canInitializePresentation(hasVideo: video, hasSize: size, externalRequested: external) == expected)
        }
        let endings: [(Bool, Bool, Int64, Int64, Bool)] = [
            (false, true, 120000, 120000, false),
            (true, false, 120000, 120000, false),
            (true, true, 119999, 120000, false),
            (true, true, 120000, 120000, true),
            (true, true, 120001, 120000, true),
            (true, true, 0, 0, false),
            (true, true, 120000, -1, false),
        ]
        for (prepared, playing, position, duration, expected) in endings {
            precondition(GuoguoMediaPolicy.shouldCompleteAirPlay(prepared: prepared, playing: playing, positionMs: position, durationMs: duration) == expected)
        }
        print("Player media policy: \(cases.count + 4 + routes.count + holds.count + presentations.count + endings.count) cases passed")
    }
}
