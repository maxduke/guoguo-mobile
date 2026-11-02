// Selective anonymous identity recovery adapted from hongguoTV PR #42.
// GPL-3.0-only; pinned sources and local contracts: native/core/UPSTREAM.md.
package app

import (
	"context"
	"errors"
)

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

func (downloader *Downloader) hongguoPlaybackLease(ctx context.Context) (hongguoPlayerLease, error) {
	client := downloader.hongguoClient()
	for {
		identity, err := downloader.hongguoPlaybackDevice(ctx)
		if err != nil {
			return hongguoPlayerLease{}, err
		}
		client.mu.Lock()
		if client.player == identity && client.playerPending == nil {
			lease := hongguoPlayerLease{identity: identity, revision: client.playerHealth.revision}
			client.mu.Unlock()
			return lease, nil
		}
		client.mu.Unlock()
	}
}

func (client *hongguoAppClient) currentHongguoLease(lease hongguoPlayerLease) bool {
	// Caller holds client.mu. Replies from the retiring identity cannot update
	// health while its replacement registration is in flight.
	return client.playerPending == nil && client.player == lease.identity && client.playerHealth.revision == lease.revision
}

// Only complete all-empty rounds establish the identity-specific failure signal.
// Other errors break that evidence, without granting another registration.
func (downloader *Downloader) hongguoPlaybackRoundFailed(lease hongguoPlayerLease, allEmpty bool) (retry, rotate bool) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if !client.currentHongguoLease(lease) {
		return false, false
	}
	if !allEmpty {
		client.playerHealth.emptyRounds = 0
		return false, false
	}
	if client.playerHealth.rotationAttempted {
		return false, false
	}
	client.playerHealth.emptyRounds++
	return true, client.playerHealth.emptyRounds >= 2
}

func (downloader *Downloader) hongguoPlaybackModelSucceeded(lease hongguoPlayerLease) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	if client.currentHongguoLease(lease) {
		client.playerHealth = hongguoPlayerHealth{revision: client.playerHealth.revision + 1}
	}
}

func (downloader *Downloader) hongguoPlaybackRecoveryAttempted(lease hongguoPlayerLease) bool {
	client := downloader.hongguoClient()
	client.mu.Lock()
	defer client.mu.Unlock()
	return client.currentHongguoLease(lease) && client.playerHealth.rotationAttempted
}

// Claim the one registration attempt before releasing the lock. Concurrent
// playback and prefetch share playerPending; unsuccessful rotation retains the
// previous identity, and canceled registration never publishes a replacement.
func (downloader *Downloader) rotateHongguoPlaybackDevice(ctx context.Context, lease hongguoPlayerLease) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	client := downloader.hongguoClient()
	client.mu.Lock()
	if pending := client.playerPending; pending != nil {
		client.mu.Unlock()
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case <-pending.done:
			return pending.err == nil, pending.err
		}
	}
	if !client.currentHongguoLease(lease) {
		changed := client.player != lease.identity
		client.mu.Unlock()
		return changed, nil
	}
	if client.playerHealth.rotationAttempted || client.playerHealth.emptyRounds < 2 {
		client.mu.Unlock()
		return false, nil
	}
	client.playerHealth.rotationAttempted = true
	pending := &hongguoPlayerDeviceCall{done: make(chan struct{})}
	client.playerPending = pending
	client.mu.Unlock()

	identity, err := downloader.registerHongguoPlaybackDevice(ctx)
	client.mu.Lock()
	defer client.mu.Unlock()
	if ctx.Err() != nil {
		err = ctx.Err()
		// A canceled owner publishes nothing. A later active caller can make
		// the one completed recovery attempt using the retained evidence.
		client.playerHealth.rotationAttempted = false
	}
	if err == nil {
		client.player = identity
		client.playerHealth = hongguoPlayerHealth{rotationAttempted: true, revision: client.playerHealth.revision + 1}
		client.upcomingModels = nil
	}
	pending.identity, pending.err = client.player, err
	client.playerPending = nil
	close(pending.done)
	return err == nil, err
}
