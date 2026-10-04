import Foundation

// AVPlayerItem.videoComposition supports file-based media, not HLS.
// Keep the format hint: playlist URLs need not end in .m3u8.
enum GuoguoMediaPolicy {
    static func shouldHoldLocalPlayback(airPlaySessionActive: Bool, routed: Bool) -> Bool {
        return airPlaySessionActive || routed
    }

    static func allowsVideoComposition(formatHint: String?, url: URL) -> Bool {
        return formatHint?.lowercased() != "hls" && url.pathExtension.lowercased() != "m3u8"
    }
}
