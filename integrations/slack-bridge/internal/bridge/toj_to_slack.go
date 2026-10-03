package bridge

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

type sqlTx = sql.Tx

// BeforePageCommit is inside the page transaction, after the cursor is written. Only unit tests use
// it; a kill there is the same as any kill before the commit.
const BeforePageCommit = "before_page_commit"

// ApplyPage turns one Toj difference page into outbound intents and advances the cursor, in one
// transaction. A crash before the commit replays the page from the old cursor; a crash after it
// finds the intents already written. Either way nothing is lost and nothing is planned twice.
func (b *Bridge) ApplyPage(ctx context.Context, page toj.Difference) error {
	b.rememberProfiles(page.Profiles)
	touched := map[string]bool{}
	plan := func(tx *sql.Tx) error {
		for _, u := range page.Updates {
			b.Stats.TojUpdatesSeen.Add(1)
			if err := b.planUpdate(ctx, tx, u, touched); err != nil {
				return err
			}
		}
		return nil
	}
	if b.Controls.CursorOutsideTx {
		// Negative control: the cursor commits on its own, then the intents. A kill between the
		// two loses the page.
		if err := b.Store.Tx(ctx, func(tx *sql.Tx) error { return store.SetCursor(ctx, tx, page.State.PTS) }); err != nil {
			return err
		}
		if len(page.Updates) > 0 {
			if err := b.reach(faults.AfterCursorCommit); err != nil {
				return err
			}
		}
		if err := b.Store.Tx(ctx, plan); err != nil {
			return err
		}
	} else {
		err := b.Store.Tx(ctx, func(tx *sql.Tx) error {
			if err := plan(tx); err != nil {
				return err
			}
			if err := store.SetCursor(ctx, tx, page.State.PTS); err != nil {
				return err
			}
			if len(page.Updates) > 0 {
				return b.reach(BeforePageCommit) // a crash here rolls the whole page back
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	for channel := range touched {
		b.wakeChannel(channel)
	}
	return nil
}

func (b *Bridge) planUpdate(ctx context.Context, tx *sql.Tx, u toj.Update, touched map[string]bool) error {
	m := u.Message
	if m == nil {
		return nil
	}
	pair, ok := b.byDialog[m.DialogID]
	if !ok {
		return nil
	}
	// Loop guard, layer 1: the bridge's own Toj messages are copies of Slack messages.
	if !b.Controls.DisableLoopGuard && m.SenderAccountID == b.Toj.Session().AccountID {
		b.Stats.TojEchoesSuppressed.Add(1)
		return nil
	}
	now := time.Now()
	switch u.Type {
	case "message.new":
		if m.Kind != "text" || m.State != "visible" {
			return nil
		}
		inserted, err := store.InsertTojOrigin(ctx, tx, m.DialogID, m.MsgID, pair.SlackChannel)
		if err != nil || !inserted {
			return err
		}
		mapping, err := store.MappingByToj(ctx, tx, m.DialogID, m.MsgID)
		if err != nil {
			return err
		}
		if err := store.SetTojEditVersion(ctx, tx, mapping.ID, m.EditVersion, ""); err != nil {
			return err
		}
		touched[pair.SlackChannel] = true
		b.Stats.IntentsWritten.Add(1)
		return store.InsertIntent(ctx, tx, store.Intent{
			SlackChannel: pair.SlackChannel, TojDialog: m.DialogID, TojMsgID: m.MsgID, Op: "post",
			Text: m.Text, Username: b.tojName(m.SenderAccountID), TojEditVersion: m.EditVersion,
		}, now)
	case "message.edited":
		mapping, err := store.MappingByToj(ctx, tx, m.DialogID, m.MsgID)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		if mapping.Origin != "toj" || mapping.Deleted || m.State != "visible" || m.EditVersion <= mapping.TojEditVersion {
			return nil
		}
		if err := store.SetTojEditVersion(ctx, tx, mapping.ID, m.EditVersion, ""); err != nil {
			return err
		}
		touched[pair.SlackChannel] = true
		b.Stats.IntentsWritten.Add(1)
		return store.InsertIntent(ctx, tx, store.Intent{
			SlackChannel: pair.SlackChannel, TojDialog: m.DialogID, TojMsgID: m.MsgID, Op: "update",
			Text: m.Text, TojEditVersion: m.EditVersion,
		}, now)
	case "message.deleted", "message.expired":
		mapping, err := store.MappingByToj(ctx, tx, m.DialogID, m.MsgID)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		if mapping.Origin != "toj" || mapping.Deleted {
			return nil
		}
		if err := store.MarkDeleted(ctx, tx, mapping.ID); err != nil {
			return err
		}
		touched[pair.SlackChannel] = true
		b.Stats.IntentsWritten.Add(1)
		return store.InsertIntent(ctx, tx, store.Intent{
			SlackChannel: pair.SlackChannel, TojDialog: m.DialogID, TojMsgID: m.MsgID, Op: "delete",
		}, now)
	}
	return nil
}

func (b *Bridge) rememberProfiles(profiles []toj.Profile) {
	b.namesMu.Lock()
	defer b.namesMu.Unlock()
	for _, p := range profiles {
		if p.DisplayName != "" {
			b.tojNames[p.AccountID] = p.DisplayName
		}
	}
}

func (b *Bridge) tojName(accountID string) string {
	b.namesMu.Lock()
	defer b.namesMu.Unlock()
	if name := b.tojNames[accountID]; name != "" {
		return name + " (Toj)"
	}
	return "Toj user"
}

// runChannel drains one Slack channel's intents in id order. It is the only goroutine that calls
// Slack for this channel, so the pacer's spacing holds without locks between channels.
func (b *Bridge) runChannel(ctx context.Context, channel string) {
	pacer := b.Pacers[channel]
	b.wakeMu.Lock()
	wake := b.wakeOut[channel]
	b.wakeMu.Unlock()
	attempt := 0
	for ctx.Err() == nil {
		in, err := b.Store.NextIntent(ctx, channel)
		if errors.Is(err, store.ErrNotFound) {
			select {
			case <-ctx.Done():
				return
			case <-wake:
			case <-time.After(2 * time.Second):
			}
			continue
		}
		if err == nil {
			err = b.runIntent(ctx, pacer, in)
		}
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			b.Log.Warn("slack intent retry", "intent", in.ID, "op", in.Op, "err", err)
			if sleep(ctx, backoff(attempt)) != nil {
				return
			}
			attempt++
			continue
		}
		attempt = 0
	}
}

func (b *Bridge) runIntent(ctx context.Context, pacer *slack.Pacer, in store.Intent) error {
	switch in.Op {
	case "post":
		return b.post(ctx, pacer, in)
	case "update":
		return b.updateOrDelete(ctx, pacer, in, func(ts string) error {
			return b.Slack.UpdateMessage(ctx, in.SlackChannel, ts, slackEscape(in.Text))
		}, &b.Stats.SlackUpdates)
	case "delete":
		return b.updateOrDelete(ctx, pacer, in, func(ts string) error {
			return b.Slack.DeleteMessage(ctx, in.SlackChannel, ts)
		}, &b.Stats.SlackDeletes)
	}
	return b.finish(ctx, in, "skipped", "unknown_op")
}

func (b *Bridge) finish(ctx context.Context, in store.Intent, status, outcome string) error {
	if status == "skipped" {
		b.Stats.IntentsSkipped.Add(1)
	}
	return b.Store.Tx(ctx, func(tx *sql.Tx) error { return store.FinishIntent(ctx, tx, in.ID, status, outcome, time.Now()) })
}

// post is the crash-safe chat.postMessage: attempts is committed before the request, and an intent
// that was attempted before is first looked up in channel history by its metadata.
func (b *Bridge) post(ctx context.Context, pacer *slack.Pacer, in store.Intent) error {
	if in.Attempts > 0 && !b.Controls.DisableReconcile {
		ts, found, err := b.reconcile(ctx, pacer, in)
		if err != nil {
			return err
		}
		if found {
			b.Stats.Reconciled.Add(1)
			return b.recordPost(ctx, in, ts, "reconciled")
		}
	}
	if err := b.Store.BeginAttempt(ctx, in.ID); err != nil {
		return err
	}
	if err := pacer.Wait(ctx); err != nil {
		return err
	}
	ts, err := b.Slack.PostMessage(ctx, slack.PostParams{
		Channel: in.SlackChannel, Text: slackEscape(in.Text), Username: in.Username,
		Metadata: &slack.Metadata{EventType: slack.MetadataEventType, EventPayload: slack.MetadataPayload{
			TojDialog: in.TojDialog, TojMsgID: in.TojMsgID,
		}},
	})
	if err != nil {
		return b.slackFailure(ctx, pacer, in, err, true)
	}
	b.Stats.SlackPosts.Add(1)
	if err := b.reach(faults.AfterSlackPost); err != nil {
		return err
	}
	return b.recordPost(ctx, in, ts, "posted")
}

func (b *Bridge) recordPost(ctx context.Context, in store.Intent, ts, outcome string) error {
	return b.Store.Tx(ctx, func(tx *sql.Tx) error {
		if err := store.SetSlackTS(ctx, tx, in.TojDialog, in.TojMsgID, ts); err != nil {
			return err
		}
		return store.FinishIntent(ctx, tx, in.ID, "done", outcome, time.Now())
	})
}

// slackFailure sorts an error by what it says about Slack's state. A 429 or an ok:false answer
// means nothing was written, so the attempt is undone and no reconcile is needed. Anything else
// (timeout, reset, 5xx) leaves the outcome unknown, and the next try reconciles first.
func (b *Bridge) slackFailure(ctx context.Context, pacer *slack.Pacer, in store.Intent, err error, attempted bool) error {
	var limited *slack.RateLimitedError
	var apiErr *slack.APIError
	switch {
	case errors.As(err, &limited):
		b.Stats.SlackRateLimited.Add(1)
		if !b.Controls.IgnoreRetryAfter {
			b.rateLimited(ctx, pacer, in.SlackChannel, limited.RetryAfter)
		}
		if attempted {
			if undoErr := b.Store.UndoAttempt(ctx, in.ID); undoErr != nil {
				return undoErr
			}
		}
		return nil // the pacer already holds the next call back
	case errors.As(err, &apiErr):
		if attempted {
			if undoErr := b.Store.UndoAttempt(ctx, in.ID); undoErr != nil {
				return undoErr
			}
		}
		return b.finish(ctx, in, "skipped", "slack_"+apiErr.Code)
	default:
		b.Stats.SlackUnknownOutcomes.Add(1)
		return fmt.Errorf("%w: %v", errTransient, err)
	}
}

// reconcile looks for a post this intent already made. History is searched from shortly before
// the intent was written; the metadata names the Toj message.
func (b *Bridge) reconcile(ctx context.Context, pacer *slack.Pacer, in store.Intent) (string, bool, error) {
	if err := pacer.Wait(ctx); err != nil {
		return "", false, err
	}
	oldest := in.CreatedAt.Add(-5 * time.Minute)
	messages, err := b.Slack.History(ctx, in.SlackChannel, strconv.FormatInt(oldest.Unix(), 10)+".000000")
	if err != nil {
		var limited *slack.RateLimitedError
		if errors.As(err, &limited) && !b.Controls.IgnoreRetryAfter {
			b.rateLimited(ctx, pacer, in.SlackChannel, limited.RetryAfter)
		}
		return "", false, err
	}
	for _, m := range messages {
		if m.Metadata != nil && m.Metadata.EventType == slack.MetadataEventType &&
			m.Metadata.EventPayload.TojDialog == in.TojDialog && m.Metadata.EventPayload.TojMsgID == in.TojMsgID {
			return m.TS, true, nil
		}
	}
	return "", false, nil
}

func (b *Bridge) updateOrDelete(ctx context.Context, pacer *slack.Pacer, in store.Intent, call func(ts string) error, counter interface{ Add(int64) int64 }) error {
	mapping, err := store.MappingByToj(ctx, b.Store.DB, in.TojDialog, in.TojMsgID)
	if err != nil {
		return err
	}
	if mapping.SlackTS == "" {
		// Intents run in order, so an earlier post either recorded its ts or was skipped.
		return b.finish(ctx, in, "skipped", "no_slack_copy")
	}
	if err := pacer.Wait(ctx); err != nil {
		return err
	}
	if err := call(mapping.SlackTS); err != nil {
		if slack.IsAPIError(err, "message_not_found") {
			return b.finish(ctx, in, "done", "already_gone")
		}
		// update and delete are idempotent, so an unknown outcome is simply retried.
		return b.slackFailure(ctx, pacer, in, err, false)
	}
	counter.Add(1)
	return b.finish(ctx, in, "done", in.Op)
}

// rateLimited holds the channel back for Retry-After in this process and, through SQLite, in the
// next one if this process is killed before the wait is over.
func (b *Bridge) rateLimited(ctx context.Context, pacer *slack.Pacer, channel string, retryAfter time.Duration) {
	until := pacer.RateLimited(retryAfter)
	if err := b.Store.SaveRateLimit(ctx, channel, until); err != nil {
		b.Log.Warn("persist slack rate limit", "err", err)
	}
}
