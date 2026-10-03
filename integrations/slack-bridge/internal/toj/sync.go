package toj

import (
	"context"
	"encoding/json"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
)

func randInt64(n int64) int64 {
	if n <= 0 {
		return 0
	}
	return rand.Int64N(n)
}

// MemorySessions keeps a session in memory, for the chaos driver's human accounts.
type MemorySessions struct{ s store.Session }

func (m *MemorySessions) LoadSession(context.Context) (store.Session, error) { return m.s, nil }
func (m *MemorySessions) SaveSession(_ context.Context, s store.Session) error {
	m.s = s
	return nil
}

// PageHandler applies one difference page. It must persist the page's state.pts as the new cursor,
// in the same transaction as whatever it derives from the page, and return that cursor.
type PageHandler func(ctx context.Context, page Difference) error

// Syncer runs the catch-up loop: a WebSocket that only carries hints, and difference pages fetched
// from the stored cursor whenever a hint, a reconnect or the fallback poll says there may be more.
type Syncer struct {
	Client   *Client
	Cursor   func(context.Context) (int64, error)
	Apply    PageHandler
	Log      *slog.Logger
	Poll     time.Duration
	TooLong  atomic.Int64 // difference_too_long answers, each a gap the bridge could not mirror
	Failures atomic.Int64
	Hints    atomic.Int64
	Connects atomic.Int64
}

// Run blocks until ctx is done.
func (s *Syncer) Run(ctx context.Context) error {
	wake := make(chan struct{}, 1)
	notify := func() {
		select {
		case wake <- struct{}{}:
		default:
		}
	}
	go s.socket(ctx, notify)
	poll := s.Poll
	if poll <= 0 {
		poll = 15 * time.Second
	}
	ticker := time.NewTicker(poll)
	defer ticker.Stop()
	notify()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-wake:
		case <-ticker.C:
		}
		s.catchUp(ctx)
	}
}

func (s *Syncer) catchUp(ctx context.Context) {
	for attempt := 0; ctx.Err() == nil; {
		cursor, err := s.Cursor(ctx)
		if err == nil {
			var page Difference
			page, err = s.Client.Difference(ctx, cursor)
			if err == nil {
				if page.Kind == "difference_too_long" {
					s.TooLong.Add(1)
					s.Log.Error("toj difference_too_long: resuming from the current pts", "from", cursor, "to", page.State.PTS)
					page.Updates = nil
				}
				if err = s.Apply(ctx, page); err == nil {
					attempt = 0
					if page.Kind != "difference_slice" {
						return
					}
					continue
				}
			}
		}
		s.Failures.Add(1)
		s.Log.Warn("toj catch-up failed", "err", err)
		if sleep(ctx, backoff(attempt)) != nil {
			return
		}
		attempt++
	}
}

const (
	pingEvery   = 5 * time.Second
	socketsDead = 12 * time.Second
)

// socket keeps one hint socket open. A hint, a reconnect and a ping deadline all end in notify; the
// socket never carries content.
func (s *Syncer) socket(ctx context.Context, notify func()) {
	for attempt := 0; ctx.Err() == nil; attempt++ {
		err := s.readHints(ctx, notify)
		if ctx.Err() != nil {
			return
		}
		if IsCode(err, "access_token_expired") || isUnauthorized(err) {
			_ = s.Client.refresh(ctx, s.Client.Session().AccessToken)
		}
		if sleep(ctx, backoff(min(attempt, 4))) != nil {
			return
		}
	}
}

func isUnauthorized(err error) bool {
	tojErr, ok := err.(*Error)
	return ok && tojErr.Status == http.StatusUnauthorized
}

func (s *Syncer) readHints(ctx context.Context, notify func()) error {
	dialCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	header := http.Header{"Authorization": {"Bearer " + s.Client.Session().AccessToken}}
	conn, resp, err := websocket.Dial(dialCtx, s.Client.WebSocketURL(), &websocket.DialOptions{
		HTTPHeader: header, HTTPClient: &http.Client{Transport: &http.Transport{DisableKeepAlives: true}},
	})
	if err != nil {
		if resp != nil && resp.StatusCode == http.StatusUnauthorized {
			return &Error{Status: 401}
		}
		return err
	}
	defer conn.CloseNow()
	s.Connects.Add(1)
	notify() // hints may have been missed while disconnected

	sockCtx, stop := context.WithCancel(ctx)
	defer stop()
	var lastSeen atomic.Int64
	lastSeen.Store(time.Now().UnixNano())
	go func() {
		t := time.NewTicker(pingEvery)
		defer t.Stop()
		for {
			select {
			case <-sockCtx.Done():
				return
			case <-t.C:
				if time.Since(time.Unix(0, lastSeen.Load())) > socketsDead {
					conn.CloseNow() // a proxy that drops data silently leaves the socket open
					return
				}
				writeCtx, cancel := context.WithTimeout(sockCtx, pingEvery)
				_ = conn.Write(writeCtx, websocket.MessageText, []byte("ping"))
				cancel()
			}
		}
	}()
	for {
		_, data, err := conn.Read(sockCtx)
		if err != nil {
			return err
		}
		lastSeen.Store(time.Now().UnixNano())
		var hint struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(data, &hint) == nil && hint.Type == "sync_hint" {
			s.Hints.Add(1)
			notify()
		}
	}
}
