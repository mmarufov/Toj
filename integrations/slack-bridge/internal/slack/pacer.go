package slack

import (
	"context"
	"sync"
	"time"
)

// Pacer spaces Slack calls for one channel. chat.postMessage allows about one message per second
// per channel; a 429 pushes the next call out by Retry-After. Each channel's worker goroutine owns
// one Pacer, so channels never wait on each other.
type Pacer struct {
	MinInterval time.Duration
	Now         func() time.Time
	Sleep       func(context.Context, time.Duration) error

	mu   sync.Mutex
	next time.Time
	// RateLimits counts 429s seen. The fake Slack separately counts calls made too early.
	RateLimits Counter
}

func (p *Pacer) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Wait blocks until the channel may be called again, then reserves the next slot.
func (p *Pacer) Wait(ctx context.Context) error {
	sleep := p.Sleep
	if sleep == nil {
		sleep = sleepCtx
	}
	p.mu.Lock()
	wait := p.next.Sub(p.now())
	p.mu.Unlock()
	if err := sleep(ctx, wait); err != nil {
		return err
	}
	p.mu.Lock()
	p.next = p.now().Add(p.MinInterval)
	p.mu.Unlock()
	return nil
}

// RateLimited records a 429: no call goes out before Retry-After has passed. It returns the time
// the channel is blocked until, for the caller to persist.
func (p *Pacer) RateLimited(retryAfter time.Duration) time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	if until := p.now().Add(retryAfter); until.After(p.next) {
		p.next = until
	}
	p.RateLimits.Add(1)
	return p.next
}

// BlockUntil restores a wait recorded by an earlier process.
func (p *Pacer) BlockUntil(until time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if until.After(p.next) {
		p.next = until
	}
}
