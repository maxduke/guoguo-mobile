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

    // A selected system audio route is independent of AVPlayer's external video.
    // Hold playback until the receiver-readable item has explicitly been prepared.
    static func shouldHoldForAirPlay(routed: Bool, prepared: Bool, receiverReadable: Bool) -> Bool {
        return routed && !(prepared && receiverReadable)
    }

    // Call only after the current item reaches readyToPlay. Remote playback need
    // not produce a local presentation size before Flutter can finish setup.
    static func canInitializePresentation(hasVideo: Bool, hasSize: Bool, externalRequested: Bool) -> Bool {
        return !hasVideo || hasSize || externalRequested
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
