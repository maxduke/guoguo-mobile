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
        print("Player media policy: \(cases.count + 4) cases passed")
    }
}
