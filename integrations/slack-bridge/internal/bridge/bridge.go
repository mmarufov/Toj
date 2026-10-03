// Package bridge mirrors Toj group dialogs into Slack channels and back.
//
// Toj to Slack: each difference page is turned into outbound intents in the same SQLite
// transaction that advances the Toj cursor. One goroutine per Slack channel drains that channel's
// intents in order through a pacer.
//
// Slack to Toj: the events handler stores each delivery and acknowledges it; one worker drains the
// stored events in arrival order and sends them to Toj with deterministic idempotency keys.
package bridge

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

// Pair links one Toj group dialog to one Slack channel. Bridging is opt-in per pair.
type Pair struct {
	TojDialog    string
	SlackChannel string
}

// namespace for deterministic Toj idempotency keys derived from Slack identifiers.
var namespace = uuid.MustParse("6f1d7f4e-2a52-5b8e-9c1e-3c2b7a0d9e11")

// SlackSendID is the clientMsgId for a Slack message. Toj deduplicates sends by this key for 90
// days, so a retry collapses even if the bridge has lost every table.
func SlackSendID(channel, ts string) string {
	return uuid.NewSHA1(namespace, []byte("send:"+channel+":"+ts)).String()
}

func slackEditID(channel, ts, editedTS string, expected int64) string {
	return uuid.NewSHA1(namespace, []byte("edit:"+channel+":"+ts+":"+editedTS+":"+itoa(expected))).String()
}

func slackDeleteID(channel, ts string) string {
	return uuid.NewSHA1(namespace, []byte("delete:"+channel+":"+ts)).String()
}

type Stats struct {
	// Toj to Slack
	TojUpdatesSeen, TojEchoesSuppressed, IntentsWritten    atomic.Int64
	SlackPosts, SlackUpdates, SlackDeletes, Reconciled     atomic.Int64
	SlackRateLimited, SlackUnknownOutcomes, IntentsSkipped atomic.Int64
	// Slack to Toj
	EventsProcessed, SlackEchoesByBotID, SlackEchoesByTS  atomic.Int64
	SlackEchoesByMetadata, TojSends, TojDuplicateAcks     atomic.Int64
	TojEdits, TojEditConflicts, TojDeletes, EventsIgnored atomic.Int64
	StaleEditsDropped, TombstonesWritten, TojSendRetries  atomic.Int64
}

type Bridge struct {
	Store    *store.Store
	Toj      *toj.Client
	Slack    *slack.Client
	Pairs    []Pair
	BotID    string // the bridge's Slack bot id, from auth.test
	AppID    string // the bridge's Slack app id, from config
	Controls faults.Controls
	// MinInterval spaces calls per Slack channel. Slack documents about 1 post per second.
	MinInterval time.Duration
	Log         *slog.Logger
	Stats       Stats

	byDialog  map[string]Pair
	byChannel map[string]Pair

	namesMu   sync.Mutex
	tojNames  map[string]string
	slackName map[string]string

	wakeMu     sync.Mutex
	wakeOut    map[string]chan struct{}
	EventsWake chan struct{}
	Pacers     map[string]*slack.Pacer

	// crash stands in for a kill -9 in unit tests: at a named point it returns an error that aborts
	// the operation exactly where the process would have died. Nil outside tests.
	crash func(point string) error
}

func (b *Bridge) reach(point string) error {
	faults.Reach(point)
	if b.crash != nil {
		return b.crash(point)
	}
	return nil
}

func (b *Bridge) init() {
	b.byDialog = map[string]Pair{}
	b.byChannel = map[string]Pair{}
	b.wakeOut = map[string]chan struct{}{}
	b.Pacers = map[string]*slack.Pacer{}
	b.tojNames = map[string]string{}
	b.slackName = map[string]string{}
	for _, p := range b.Pairs {
		b.byDialog[p.TojDialog] = p
		b.byChannel[p.SlackChannel] = p
		b.wakeOut[p.SlackChannel] = make(chan struct{}, 1)
		b.Pacers[p.SlackChannel] = &slack.Pacer{MinInterval: b.MinInterval}
	}
	if b.EventsWake == nil {
		b.EventsWake = make(chan struct{}, 1)
	}
}

// Prepare must run before Run and before the events handler is served.
func (b *Bridge) Prepare(ctx context.Context) error {
	b.init()
	if _, ok, err := b.Store.Cursor(ctx); err != nil {
		return err
	} else if !ok {
		// A new bridge mirrors from now on; it does not replay the group's history into Slack.
		pts, err := b.Toj.State(ctx)
		if err != nil {
			return err
		}
		return b.Store.Tx(ctx, func(tx *sqlTx) error { return store.SetCursor(ctx, tx, pts) })
	}
	return nil
}

// Run starts every loop and blocks until ctx is done.
func (b *Bridge) Run(ctx context.Context, syncer *toj.Syncer) error {
	var wg sync.WaitGroup
	for _, p := range b.Pairs {
		wg.Add(1)
		go func(channel string) {
			defer wg.Done()
			b.runChannel(ctx, channel)
		}(p.SlackChannel)
	}
	wg.Add(2)
	go func() { defer wg.Done(); b.runEvents(ctx) }()
	go func() { defer wg.Done(); b.runPruner(ctx) }()
	err := syncer.Run(ctx)
	wg.Wait()
	return err
}

func (b *Bridge) wakeChannel(channel string) {
	b.wakeMu.Lock()
	ch := b.wakeOut[channel]
	b.wakeMu.Unlock()
	select {
	case ch <- struct{}{}:
	default:
	}
}

func (b *Bridge) runPruner(ctx context.Context) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		if _, err := b.Store.PruneEvents(ctx, time.Now()); err != nil && ctx.Err() == nil {
			b.Log.Warn("prune slack events", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Text helpers. Slack escapes &, < and > in message text; Toj stores plain text.

func slackEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

func slackUnescape(s string) string {
	return strings.NewReplacer("&lt;", "<", "&gt;", ">", "&amp;", "&").Replace(s)
}

// TojTextForSlackMessage is how a Slack message reads inside Toj.
func TojTextForSlackMessage(name, slackText string) string {
	return name + ": " + slackUnescape(slackText)
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	neg := v < 0
	if neg {
		v = -v
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func backoff(attempt int) time.Duration {
	d := 200 * time.Millisecond << min(attempt, 4)
	return min(d, 3*time.Second)
}

var errTransient = errors.New("transient")
