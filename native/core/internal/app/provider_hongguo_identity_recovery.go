// Bounded empty-model errors for anonymous per-resolve playback.
// GPL-3.0-only; pinned sources and local contracts: native/core/UPSTREAM.md.
package app

import "errors"

type hongguoEmptyPlaybackError struct {
	attempts int
}

func (*hongguoEmptyPlaybackError) Error() string {
	return "红果 App 接口未返回有效数据"
}

var errHongguoPlaybackRecoveryExhausted = errors.New("红果播放恢复后仍未返回有效数据，请稍后重试或切换网络")

func hongguoEmptyAttemptCount(err error) int {
	var empty *hongguoEmptyPlaybackError
	if errors.As(err, &empty) {
		return empty.attempts
	}
	return -1
}
