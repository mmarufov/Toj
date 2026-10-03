package bridge

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slackfake"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
)

func TestTojMessageIsMirroredToSlackOnce(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	h.toj.Send(h.alice, h.dialog, "c1", "hello <team> & co")
	h.settle()

	posts := h.slackBotPosts()
	if len(posts) != 1 {
		t.Fatalf("slack posts = %d, want 1", len(posts))
	}
	if posts[0].Text != "hello &lt;team&gt; &amp; co" || posts[0].Username != "Alice (Toj)" {
		t.Fatalf("post = %+v", posts[0])
	}
	md := posts[0].Metadata
	if md == nil || md.EventType != slack.MetadataEventType || md.EventPayload.TojMsgID != 1 {
		t.Fatalf("metadata = %+v", md)
	}
	if got := h.tojFrom(h.bridgeAccount); len(got) != 0 {
		t.Fatalf("the bridge's own post came back into Toj: %+v", got)
	}
	if h.b.Stats.SlackEchoesByBotID.Load() != 1 {
		t.Fatalf("echoes by bot id = %d, want 1", h.b.Stats.SlackEchoesByBotID.Load())
	}
}

func TestSlackMessageIsMirroredToTojOnce(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	h.slack.HumanPost(testChannel, "U0ALICE", "ship it &amp; &lt;now&gt;")
	h.settle()

	got := h.tojFrom(h.bridgeAccount)
	if len(got) != 1 || got[0].Text != "alice: ship it & <now>" {
		t.Fatalf("toj copies = %+v", got)
	}
	if posts := h.slackBotPosts(); len(posts) != 0 {
		t.Fatalf("the Toj copy was mirrored back to Slack: %+v", posts)
	}
	if h.b.Stats.TojEchoesSuppressed.Load() != 1 {
		t.Fatalf("toj echoes suppressed = %d, want 1", h.b.Stats.TojEchoesSuppressed.Load())
	}
}

// Negative control: with the loop guard off, one message bounces between the systems.
func TestLoopGuardOffEchoes(t *testing.T) {
	h := newHarness(t, harnessOptions{controls: faults.Controls{DisableLoopGuard: true}})
	h.toj.Send(h.alice, h.dialog, "c1", "hello")
	h.settle()
	if echoes := len(h.tojFrom(h.bridgeAccount)); echoes == 0 {
		t.Fatal("expected echoes in Toj with the loop guard off")
	}
	if posts := len(h.slackBotPosts()); posts < 2 {
		t.Fatalf("slack posts = %d, expected the echo to be mirrored again", posts)
	}
}

// The ts check in layer 2 works without a bot id: a deployment that lost its identity still does
// not echo its own posts.
func TestLoopGuardByTimestampWithoutBotID(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	h.b.BotID, h.b.AppID = "", ""
	h.toj.Send(h.alice, h.dialog, "c1", "hello")
	h.settle()
	if got := h.tojFrom(h.bridgeAccount); len(got) != 0 {
		t.Fatalf("echo: %+v", got)
	}
	if h.b.Stats.SlackEchoesByTS.Load() == 0 {
		t.Fatal("expected the ts layer to catch the echo")
	}
}

// Layer 3 covers the crash window layer 2 cannot: Slack accepted the post, the bridge died before
// recording its ts, and (here) no bot id is configured. Only the metadata identifies the echo.
func TestMetadataCatchesEchoOfUnrecordedPost(t *testing.T) {
	for _, withMetadata := range []bool{true, false} {
		t.Run(fmt.Sprintf("events_include_metadata=%v", withMetadata), func(t *testing.T) {
			h := newHarness(t, harnessOptions{slack: slackfake.Config{EventsIncludeMetadata: withMetadata}})
			h.b.BotID, h.b.AppID = "", ""
			h.toj.Send(h.alice, h.dialog, "c1", "hello")
			if err := h.syncToj(); err != nil {
				t.Fatal(err)
			}
			h.crashAt(faults.AfterSlackPost)
			if err := h.drainIntents(); err == nil {
				t.Fatal("expected the simulated crash")
			}
			// The echo event is processed before the restart reconciles the post.
			if err := h.drainEvents(); err != nil {
				t.Fatal(err)
			}
			echoes := len(h.tojFrom(h.bridgeAccount))
			if withMetadata && echoes != 0 {
				t.Fatalf("metadata layer missed the echo: %d", echoes)
			}
			if !withMetadata && echoes == 0 {
				t.Fatal("control: without metadata, bot id or a recorded ts the echo should get through")
			}
		})
	}
}

func TestSlackRetriesAndDuplicatesAreAbsorbed(t *testing.T) {
	retrying := slackfake.Config{PDuplicate: 1, PSlowAck: 1}
	cases := []struct {
		name     string
		controls faults.Controls
		wantOne  bool
	}{
		{"both layers", faults.Controls{}, true},
		{"bridge dedupe off (event_id and map), Toj clientMsgId still collapses retries", faults.Controls{DisableEventDedupe: true}, true},
		{"deterministic clientMsgId off, bridge dedupe still holds", faults.Controls{RandomTojIDs: true}, true},
		{"control: both off", faults.Controls{DisableEventDedupe: true, RandomTojIDs: true}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, harnessOptions{controls: tc.controls, slack: retrying})
			h.slack.HumanPost(testChannel, "U0ALICE", "once")
			h.settle()
			stats := h.slack.Stats()
			if stats.RetryDeliveries == 0 || stats.DuplicatesInjected == 0 {
				t.Fatalf("fake did not retry: %+v", stats)
			}
			copies := len(h.tojFrom(h.bridgeAccount))
			if tc.wantOne && copies != 1 {
				t.Fatalf("toj copies = %d, want 1", copies)
			}
			if !tc.wantOne && copies < 2 {
				t.Fatalf("toj copies = %d, control expected duplicates", copies)
			}
		})
	}
}

func TestCrashAfterSlackPostIsReconciled(t *testing.T) {
	for _, reconcile := range []bool{true, false} {
		t.Run(fmt.Sprintf("reconcile=%v", reconcile), func(t *testing.T) {
			h := newHarness(t, harnessOptions{controls: faults.Controls{DisableReconcile: !reconcile}})
			h.toj.Send(h.alice, h.dialog, "c1", "exactly once")
			if err := h.syncToj(); err != nil {
				t.Fatal(err)
			}
			h.crashAt(faults.AfterSlackPost)
			if err := h.drainIntents(); err == nil {
				t.Fatal("expected the simulated crash")
			}
			h.restart()
			h.settle()
			posts := len(h.slackBotPosts())
			if reconcile && (posts != 1 || h.b.Stats.Reconciled.Load() != 1) {
				t.Fatalf("posts = %d reconciled = %d, want 1 and 1", posts, h.b.Stats.Reconciled.Load())
			}
			if !reconcile && posts != 2 {
				t.Fatalf("control: posts = %d, want the duplicate", posts)
			}
		})
	}
}

func TestCrashAfterTojSendDoesNotDuplicate(t *testing.T) {
	for _, deterministic := range []bool{true, false} {
		t.Run(fmt.Sprintf("deterministic_client_msg_id=%v", deterministic), func(t *testing.T) {
			h := newHarness(t, harnessOptions{controls: faults.Controls{RandomTojIDs: !deterministic}})
			h.slack.HumanPost(testChannel, "U0ALICE", "once")
			h.crashAt(faults.AfterTojSend)
			if err := h.drainEvents(); err == nil {
				t.Fatal("expected the simulated crash")
			}
			h.restart()
			h.settle()
			copies := len(h.tojFrom(h.bridgeAccount))
			if deterministic && copies != 1 {
				t.Fatalf("toj copies = %d, want 1", copies)
			}
			if !deterministic && copies != 2 {
				t.Fatalf("control: toj copies = %d, want 2", copies)
			}
		})
	}
}

func TestCursorAdvancesInTheSameTransactionAsIntents(t *testing.T) {
	t.Run("one transaction", func(t *testing.T) {
		h := newHarness(t, harnessOptions{})
		h.toj.Send(h.alice, h.dialog, "c1", "not lost")
		h.crashAt(BeforePageCommit)
		if err := h.syncToj(); err == nil {
			t.Fatal("expected the simulated crash")
		}
		h.restart()
		h.settle()
		if posts := len(h.slackBotPosts()); posts != 1 {
			t.Fatalf("slack posts = %d, want 1", posts)
		}
	})
	t.Run("control: cursor committed separately", func(t *testing.T) {
		h := newHarness(t, harnessOptions{controls: faults.Controls{CursorOutsideTx: true}})
		h.toj.Send(h.alice, h.dialog, "c1", "lost")
		h.crashAt(faults.AfterCursorCommit)
		if err := h.syncToj(); err == nil {
			t.Fatal("expected the simulated crash")
		}
		h.restart()
		h.settle()
		if posts := len(h.slackBotPosts()); posts != 0 {
			t.Fatalf("slack posts = %d, the control should lose the page", posts)
		}
	})
}

func TestEditsAndDeletesMirrorBothWays(t *testing.T) {
	h := newHarness(t, harnessOptions{})

	// Toj to Slack.
	msgID := h.toj.Send(h.alice, h.dialog, "c1", "draft")
	h.settle()
	h.toj.Edit(h.alice, h.dialog, msgID, "final")
	h.settle()
	posts := h.slackBotPosts()
	if len(posts) != 1 || posts[0].Text != "final" || posts[0].Edited == nil {
		t.Fatalf("slack after toj edit = %+v", posts)
	}
	h.toj.Delete(h.alice, h.dialog, msgID)
	h.settle()
	if posts := h.slackBotPosts(); len(posts) != 1 || !posts[0].Deleted {
		t.Fatalf("slack after toj delete = %+v", posts)
	}

	// Slack to Toj.
	ts := h.slack.HumanPost(testChannel, "U0BOB", "typo")
	h.settle()
	h.slack.HumanEdit(testChannel, ts, "U0BOB", "fixed")
	h.settle()
	copies := h.tojFrom(h.bridgeAccount)
	if len(copies) != 1 || copies[0].Text != "bob: fixed" || copies[0].EditVersion != 1 {
		t.Fatalf("toj after slack edit = %+v", copies)
	}
	h.slack.HumanDelete(testChannel, ts, "U0BOB")
	h.settle()
	copies = h.tojFrom(h.bridgeAccount)
	if len(copies) != 1 || copies[0].State != "deleted_for_all" {
		t.Fatalf("toj after slack delete = %+v", copies)
	}
	// Nothing the bridge did came back as a new message on either side.
	if len(h.slackBotPosts()) != 1 || len(h.tojFrom(h.bridgeAccount)) != 1 {
		t.Fatal("an edit or delete echoed")
	}
}

func envelope(t *testing.T, id string, event map[string]any) []byte {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"type": "event_callback", "event_id": id, "event": event})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func (h *harness) store(id string, event map[string]any) {
	h.t.Helper()
	if _, err := h.st.InsertEvent(h.ctx, id, envelope(h.t, id, event), time.Now()); err != nil {
		h.t.Fatal(err)
	}
}

// Slack does not order deliveries: an edit can arrive before the message it edits, and an older
// edit after a newer one.
func TestReorderedSlackEventsConverge(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	ts := "1700000000.000100"
	msg := func(text, edited string) map[string]any {
		m := map[string]any{"type": "message", "user": "U0ALICE", "text": text, "ts": ts}
		if edited != "" {
			m["edited"] = map[string]any{"user": "U0ALICE", "ts": edited}
		}
		return m
	}
	changed := func(text, edited string) map[string]any {
		return map[string]any{"type": "message", "subtype": "message_changed", "channel": testChannel, "message": msg(text, edited)}
	}
	h.store("Ev2", changed("second edit", "1700000000.000300"))
	h.store("Ev1", changed("first edit", "1700000000.000200"))
	h.store("Ev0", map[string]any{"type": "message", "channel": testChannel, "user": "U0ALICE", "text": "original", "ts": ts})
	h.settle()
	copies := h.tojFrom(h.bridgeAccount)
	if len(copies) != 1 || copies[0].Text != "alice: second edit" {
		t.Fatalf("toj = %+v", copies)
	}

	// A delete delivered before its message leaves a tombstone, so the late message is skipped.
	h.store("Ev4", map[string]any{"type": "message", "subtype": "message_deleted", "channel": testChannel, "deleted_ts": "1700000001.000100"})
	h.store("Ev3", map[string]any{"type": "message", "channel": testChannel, "user": "U0ALICE", "text": "gone", "ts": "1700000001.000100"})
	h.settle()
	if copies := h.tojFrom(h.bridgeAccount); len(copies) != 1 {
		t.Fatalf("a deleted message was mirrored: %+v", copies)
	}
}

// The bridge relies on Toj answering a stale edit with 409 edit_conflict and the current version:
// it retries on that version instead of dropping the edit as a bad request.
func TestStaleEditVersionIsRetriedOnTheCurrentVersion(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	ts := h.slack.HumanPost(testChannel, "U0ALICE", "v0")
	h.settle()
	copyID := h.tojFrom(h.bridgeAccount)[0].MsgID
	// The bridge's copy moved on without the map knowing, as after a crash between the server
	// committing an edit and the bridge recording it.
	h.toj.Edit(h.bridgeAccount, h.dialog, copyID, "alice: v1")
	h.slack.HumanEdit(testChannel, ts, "U0ALICE", "v2")
	h.settle()
	copies := h.tojFrom(h.bridgeAccount)
	if copies[0].Text != "alice: v2" || h.b.Stats.TojEditConflicts.Load() != 1 {
		t.Fatalf("toj = %+v conflicts = %d", copies, h.b.Stats.TojEditConflicts.Load())
	}
}

func TestRetryAfterIsHonored(t *testing.T) {
	limited := slackfake.Config{PRateLimit: 0.5, RetryAfter: time.Second, Seed: 7}
	for _, honor := range []bool{true, false} {
		t.Run(fmt.Sprintf("honor=%v", honor), func(t *testing.T) {
			h := newHarness(t, harnessOptions{slack: limited, controls: faults.Controls{IgnoreRetryAfter: !honor}})
			for i := 0; i < 4; i++ {
				h.toj.Send(h.alice, h.dialog, fmt.Sprintf("c%d", i), fmt.Sprintf("m%d", i))
			}
			h.settle()
			stats := h.slack.Stats()
			if stats.RateLimited == 0 {
				t.Fatal("fake injected no 429")
			}
			if honor && stats.RateLimitViolations != 0 {
				t.Fatalf("calls during Retry-After = %d, want 0", stats.RateLimitViolations)
			}
			if !honor && stats.RateLimitViolations == 0 {
				t.Fatal("control: expected calls during Retry-After")
			}
			if len(h.slackBotPosts()) != 4 {
				t.Fatalf("posts = %d, want 4", len(h.slackBotPosts()))
			}
		})
	}
}

// Row absence in slack_events decides whether a delivery is processed. Present: a retry is
// absorbed. Pruned: a redelivery is processed again, and Toj's clientMsgId still makes it a no-op.
func TestPrunedEventIDRedeliveryIsBenign(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	raw := envelope(t, "EvSAME", map[string]any{"type": "message", "channel": testChannel, "user": "U0ALICE", "text": "hi", "ts": "1700000002.000100"})
	now := time.Now()
	if ok, _ := h.st.InsertEvent(h.ctx, "EvSAME", raw, now); !ok {
		t.Fatal("first insert")
	}
	h.settle()
	if ok, _ := h.st.InsertEvent(h.ctx, "EvSAME", raw, now.Add(time.Hour)); ok {
		t.Fatal("row present: a retry must be absorbed")
	}
	if n, err := h.st.PruneEvents(h.ctx, now.Add(store.EventRetention+time.Minute)); err != nil || n != 1 {
		t.Fatalf("pruned %d (%v), want 1", n, err)
	}
	if ok, _ := h.st.InsertEvent(h.ctx, "EvSAME", raw, now.Add(store.EventRetention+2*time.Minute)); !ok {
		t.Fatal("row absent: the redelivery is processed again")
	}
	// The mapping row makes the reprocessing a no-op; drop it too, as if the bridge had lost
	// every table, and Toj's own idempotency still holds.
	if _, err := h.st.DB.Exec(`DELETE FROM message_map`); err != nil {
		t.Fatal(err)
	}
	h.settle()
	if copies := h.tojFrom(h.bridgeAccount); len(copies) != 1 {
		t.Fatalf("toj copies = %d, want 1", len(copies))
	}
	if h.b.Stats.TojDuplicateAcks.Load() != 1 {
		t.Fatalf("duplicate acks = %d, want 1", h.b.Stats.TojDuplicateAcks.Load())
	}
}

func TestPendingEventsAreNeverPruned(t *testing.T) {
	h := newHarness(t, harnessOptions{})
	now := time.Now()
	if _, err := h.st.InsertEvent(context.Background(), "EvPENDING", []byte(`{}`), now); err != nil {
		t.Fatal(err)
	}
	if n, _ := h.st.PruneEvents(h.ctx, now.Add(10*store.EventRetention)); n != 0 {
		t.Fatalf("pruned %d pending events", n)
	}
}

// Retry-After outlives the process that received it. Row present: the restarted bridge still
// waits. Row absent: it calls at once.
func TestRetryAfterSurvivesARestart(t *testing.T) {
	for _, keepRow := range []bool{true, false} {
		t.Run(fmt.Sprintf("row_present=%v", keepRow), func(t *testing.T) {
			h := newHarness(t, harnessOptions{})
			h.b.rateLimited(h.ctx, h.b.Pacers[testChannel], testChannel, 2*time.Second)
			if !keepRow {
				if _, err := h.st.DB.Exec(`DELETE FROM slack_rate_limits`); err != nil {
					t.Fatal(err)
				}
			}
			h.restart()
			h.toj.Send(h.alice, h.dialog, "c1", "after a 429")
			if err := h.syncToj(); err != nil {
				t.Fatal(err)
			}
			started := time.Now()
			if err := h.drainIntents(); err != nil {
				t.Fatal(err)
			}
			waited := time.Since(started)
			if keepRow && waited < 1500*time.Millisecond {
				t.Fatalf("posted after %s, inside the stored Retry-After", waited)
			}
			if !keepRow && waited > 500*time.Millisecond {
				t.Fatalf("waited %s with no stored Retry-After", waited)
			}
		})
	}
}
