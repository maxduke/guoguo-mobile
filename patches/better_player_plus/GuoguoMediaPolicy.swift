import Foundation

// AVPlayerItem.videoComposition supports file-based media, not HLS.
// Keep the format hint: playlist URLs need not end in .m3u8.
enum GuoguoMediaPolicy {
    static func canUseAirPlay(url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host?.lowercased(),
              !host.isEmpty, host != "localhost", host != "::1", host != "[::1]",
              !host.hasPrefix("127.") else { return false }
        return true
    }

    static func shouldCompleteAirPlay(prepared: Bool, playing: Bool, positionMs: Int64, durationMs: Int64) -> Bool {
        return prepared && playing && durationMs > 0 && positionMs >= durationMs
    }

    static func shouldPauseInBackground(pipActive: Bool, externalPlaybackActive: Bool) -> Bool {
        return !pipActive && !externalPlaybackActive
    }

    static func allowsVideoComposition(formatHint: String?, url: URL) -> Bool {
        return formatHint?.lowercased() != "hls" && url.pathExtension.lowercased() != "m3u8"
    }
}
