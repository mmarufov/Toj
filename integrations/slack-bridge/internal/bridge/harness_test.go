package bridge

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slackfake"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/tojfake"
)

const (
	testSecret  = "test-signing-secret"
	testToken   = "xoxb-test"
	testChannel = "C0BRIDGE"
	botID       = "B0BRIDGE"
	appID       = "A0BRIDGE"
)

// harness wires a bridge to an in-memory Toj and a fake Slack, and runs its loops step by step so
// a test can stop exactly where a crash would.
type harness struct {
	t         *testing.T
	ctx       context.Context
	toj       *tojfake.Fake
	slack     *slackfake.Fake
	events    *httptest.Server
	dbPath    string
	st        *store.Store
	b         *Bridge
	controls  faults.Controls
	slackBase string

	alice, aliceToken string // a Toj group member
	bridgeAccount     string
	dialog            string
}

type harnessOptions struct {
	controls faults.Controls
	slack    slackfake.Config
}

func newHarness(t *testing.T, opts harnessOptions) *harness {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	h := &harness{t: t, ctx: ctx, controls: opts.controls, dbPath: filepath.Join(t.TempDir(), "bridge.db")}
	h.toj = tojfake.New()
	t.Cleanup(h.toj.Close)
	var aliceRefresh, bridgeAccess, bridgeRefresh string
	h.alice, h.aliceToken, aliceRefresh = h.toj.Account("Alice")
	_ = aliceRefresh
	h.bridgeAccount, bridgeAccess, bridgeRefresh = h.toj.Account("Slack bridge")
	h.dialog = h.toj.Group(h.alice, h.bridgeAccount)

	cfg := opts.slack
	cfg.SigningSecret, cfg.BotToken, cfg.BotID, cfg.AppID, cfg.BotUserID = testSecret, testToken, botID, appID, "U0BRIDGE"
	if cfg.RetrySchedule == nil {
		cfg.RetrySchedule = []time.Duration{10 * time.Millisecond, 20 * time.Millisecond, 40 * time.Millisecond}
	}
	if cfg.RetryAfter == 0 {
		cfg.RetryAfter = time.Second
	}
	h.slack = slackfake.New(cfg)
	h.slack.AddUser("U0ALICE", "alice")
	h.slack.AddUser("U0BOB", "bob")
	base, err := h.slack.Start("127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	h.slackBase = base
	t.Cleanup(h.slack.Close)

	st, err := store.Open(h.dbPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSession(ctx, store.Session{AccountID: h.bridgeAccount, DeviceID: "d", AccessToken: bridgeAccess, RefreshToken: bridgeRefresh}); err != nil {
		t.Fatal(err)
	}
	st.Close()
	h.start()
	t.Cleanup(func() { h.st.Close() })
	return h
}

// start opens the store and builds a bridge, as a process start does.
func (h *harness) start() {
	h.t.Helper()
	st, err := store.Open(h.dbPath)
	if err != nil {
		h.t.Fatal(err)
	}
	h.st = st
	client := toj.NewClient(h.toj.Server.URL, st)
	if err := client.Load(h.ctx); err != nil {
		h.t.Fatal(err)
	}
	slackClient := slack.NewClient(h.slackURL(), testToken)
	h.b = &Bridge{
		Store: st, Toj: client, Slack: slackClient,
		Pairs: []Pair{{TojDialog: h.dialog, SlackChannel: testChannel}},
		BotID: botID, AppID: appID, Controls: h.controls, Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	if err := h.b.Prepare(h.ctx); err != nil {
		h.t.Fatal(err)
	}
	handler := &slack.EventsHandler{Secret: []byte(testSecret), Store: st, Wake: h.b.EventsWake,
		Controls: h.controls, Log: h.b.Log}
	if h.events != nil {
		h.events.Close()
	}
	h.events = httptest.NewServer(handler)
	h.slack.SetEventsURL(h.events.URL)
}

func (h *harness) slackURL() string { return h.slackBase }

// restart is a kill -9 and a fresh process on the same SQLite file.
func (h *harness) restart() {
	h.t.Helper()
	h.st.Close()
	h.b.crash = nil
	h.start()
}

// syncToj pages the Toj difference into intents until caught up.
func (h *harness) syncToj() error {
	for i := 0; i < 100; i++ {
		cursor, _, err := h.st.Cursor(h.ctx)
		if err != nil {
			return err
		}
		page, err := h.b.Toj.Difference(h.ctx, cursor)
		if err != nil {
			return err
		}
		if err := h.b.ApplyPage(h.ctx, page); err != nil {
			return err
		}
		if page.Kind == "difference" {
			return nil
		}
	}
	return errors.New("difference did not finish")
}

// drainIntents runs the channel's intents until none is pending. Errors are retried, as the
// channel goroutine does, but a crash error stops the drain.
func (h *harness) drainIntents() error {
	pacer := h.b.Pacers[testChannel]
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		in, err := h.st.NextIntent(h.ctx, testChannel)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := h.b.runIntent(h.ctx, pacer, in); err != nil {
			if errors.Is(err, errCrash) {
				return err
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	return errors.New("intents did not drain")
}

// drainEvents waits for the fake to finish delivering, then processes stored events.
func (h *harness) drainEvents() error {
	ctx, cancel := context.WithTimeout(h.ctx, 10*time.Second)
	defer cancel()
	if err := h.slack.Drain(ctx); err != nil {
		return err
	}
	for i := 0; i < 1000; i++ {
		events, err := h.st.PendingEvents(h.ctx, 100)
		if err != nil {
			return err
		}
		if len(events) == 0 {
			return nil
		}
		for _, e := range events {
			if err := h.b.processEvent(h.ctx, e); err != nil {
				if errors.Is(err, errCrash) {
					return err
				}
				time.Sleep(5 * time.Millisecond)
				break
			}
		}
	}
	return errors.New("events did not drain")
}

var errCrash = errors.New("simulated kill -9")

func (h *harness) crashAt(point string) {
	h.b.crash = func(p string) error {
		if p == point {
			return errCrash
		}
		return nil
	}
}

func (h *harness) settle() {
	h.t.Helper()
	for i := 0; i < 5; i++ {
		if err := h.drainEvents(); err != nil {
			h.t.Fatal(err)
		}
		if err := h.syncToj(); err != nil {
			h.t.Fatal(err)
		}
		if err := h.drainIntents(); err != nil {
			h.t.Fatal(err)
		}
	}
}

func (h *harness) tojFrom(account string) []tojfake.Message {
	var out []tojfake.Message
	for _, m := range h.toj.Messages(h.dialog) {
		if m.SenderAccountID == account {
			out = append(out, m)
		}
	}
	return out
}

func (h *harness) slackBotPosts() []slackfake.Msg {
	var out []slackfake.Msg
	for _, m := range h.slack.Messages(testChannel) {
		if m.BotID == botID {
			out = append(out, m)
		}
	}
	return out
}
