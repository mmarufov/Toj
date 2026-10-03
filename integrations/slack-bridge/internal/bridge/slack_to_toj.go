package bridge

import (
	"context"

	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"strconv"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

type messageEvent struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype"`
	Channel         string          `json:"channel"`
	User            string          `json:"user"`
	Username        string          `json:"username"`
	Text            string          `json:"text"`
	TS              string          `json:"ts"`
	ThreadTS        string          `json:"thread_ts"`
	BotID           string          `json:"bot_id"`
	AppID           string          `json:"app_id"`
	Metadata        *slack.Metadata `json:"metadata"`
	Message         *slack.Message  `json:"message"`
	PreviousMessage *slack.Message  `json:"previous_message"`
	DeletedTS       string          `json:"deleted_ts"`
}

func (e messageEvent) asMessage() slack.Message {
	return slack.Message{Type: e.Type, Subtype: e.Subtype, User: e.User, BotID: e.BotID, AppID: e.AppID,
		Text: e.Text, TS: e.TS, ThreadTS: e.ThreadTS, Metadata: e.Metadata, Username: e.Username}
}

// runEvents drains stored Slack events in arrival order. A transient failure retries the same
// event, so a later event never overtakes an earlier one that is still failing.
func (b *Bridge) runEvents(ctx context.Context) {
	attempt := 0
	for ctx.Err() == nil {
		events, err := b.Store.PendingEvents(ctx, 100)
		if err == nil && len(events) == 0 {
			select {
			case <-ctx.Done():
				return
			case <-b.EventsWake:
			case <-time.After(2 * time.Second):
			}
			continue
		}
		for _, e := range events {
			if err = b.processEvent(ctx, e); err != nil {
				break
			}
			b.Stats.EventsProcessed.Add(1)
		}
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			b.Log.Warn("slack event retry", "err", err)
			if sleep(ctx, backoff(attempt)) != nil {
				return
			}
			attempt++
			continue
		}
		attempt = 0
	}
}

func (b *Bridge) finishEvent(ctx context.Context, e store.PendingEvent, outcome string, extra func(*sql.Tx) error) error {
	return b.Store.Tx(ctx, func(tx *sql.Tx) error {
		if extra != nil {
			if err := extra(tx); err != nil {
				return err
			}
		}
		return store.FinishEvent(ctx, tx, e.Seq, outcome)
	})
}

func (b *Bridge) ignore(ctx context.Context, e store.PendingEvent, outcome string) error {
	b.Stats.EventsIgnored.Add(1)
	return b.finishEvent(ctx, e, outcome, nil)
}

func (b *Bridge) processEvent(ctx context.Context, e store.PendingEvent) error {
	var env slack.Envelope
	if err := json.Unmarshal(e.Payload, &env); err != nil {
		return b.ignore(ctx, e, "undecodable")
	}
	var ev messageEvent
	if err := json.Unmarshal(env.Event, &ev); err != nil || ev.Type != "message" {
		return b.ignore(ctx, e, "not_a_message")
	}
	pair, ok := b.byChannel[ev.Channel]
	if !ok {
		return b.ignore(ctx, e, "channel_not_bridged")
	}
	switch ev.Subtype {
	case "", "bot_message", "thread_broadcast":
		return b.slackNew(ctx, e, pair, ev.asMessage())
	case "message_changed":
		return b.slackEdit(ctx, e, pair, ev)
	case "message_deleted":
		return b.slackDelete(ctx, e, pair, ev)
	default:
		return b.ignore(ctx, e, "subtype_"+ev.Subtype)
	}
}

// isEcho is the loop guard on the Slack side. Layer 2 is the bot and app id and the ts of the
// bridge's own posts; layer 3 is the metadata every bridge post carries.
func (b *Bridge) isEcho(ctx context.Context, channel string, m *slack.Message) (bool, error) {
	if b.Controls.DisableLoopGuard || m == nil {
		return false, nil
	}
	if (b.BotID != "" && m.BotID == b.BotID) || (b.AppID != "" && m.AppID == b.AppID) {
		b.Stats.SlackEchoesByBotID.Add(1)
		return true, nil
	}
	if m.Metadata != nil && m.Metadata.EventType == slack.MetadataEventType {
		b.Stats.SlackEchoesByMetadata.Add(1)
		return true, nil
	}
	if m.TS != "" {
		ours, err := b.Store.IsBridgePost(ctx, channel, m.TS)
		if err != nil {
			return false, err
		}
		if ours {
			b.Stats.SlackEchoesByTS.Add(1)
			return true, nil
		}
	}
	return false, nil
}

func (b *Bridge) slackNew(ctx context.Context, e store.PendingEvent, pair Pair, m slack.Message) error {
	if m.ThreadTS != "" && m.ThreadTS != m.TS {
		return b.ignore(ctx, e, "thread_reply") // threads are out of scope for the minimum bridge
	}
	if echo, err := b.isEcho(ctx, pair.SlackChannel, &m); err != nil || echo {
		if err != nil {
			return err
		}
		return b.finishEvent(ctx, e, "echo", nil)
	}
	// The map is the bridge's second dedupe of Slack deliveries, after the event_id table. A
	// Toj-origin row is the bridge's own post, which only reaches here with the loop guard off.
	if mapping, err := store.MappingBySlack(ctx, b.Store.DB, pair.SlackChannel, m.TS); err == nil {
		if mapping.Origin == "slack" && mapping.Deleted {
			return b.finishEvent(ctx, e, "tombstoned", nil)
		}
		if mapping.Origin == "slack" && !b.Controls.DisableEventDedupe {
			return b.finishEvent(ctx, e, "already_mirrored", nil)
		}
	} else if !errors.Is(err, store.ErrNotFound) {
		return err
	}
	name, err := b.slackUserName(ctx, m)
	if err != nil {
		return err
	}
	msgID, outcome, err := b.sendToToj(ctx, pair, m.TS, TojTextForSlackMessage(name, m.Text))
	if err != nil || msgID == 0 {
		if err != nil {
			return err
		}
		return b.finishEvent(ctx, e, outcome, nil)
	}
	return b.finishEvent(ctx, e, outcome, func(tx *sql.Tx) error {
		return store.InsertSlackOrigin(ctx, tx, pair.SlackChannel, m.TS, pair.TojDialog, msgID, 0)
	})
}

// sendToToj sends with clientMsgId = UUIDv5(channel, ts). A retry of the same Slack message, from
// any layer, returns the message the first attempt created.
func (b *Bridge) sendToToj(ctx context.Context, pair Pair, ts, text string) (int64, string, error) {
	clientMsgID := SlackSendID(pair.SlackChannel, ts)
	if b.Controls.RandomTojIDs {
		clientMsgID = uuid.NewString()
	}
	res, err := b.Toj.Send(ctx, pair.TojDialog, clientMsgID, text)
	if err != nil {
		if toj.Retryable(err) {
			b.Stats.TojSendRetries.Add(1)
			return 0, "", fmt.Errorf("%w: toj send: %v", errTransient, err)
		}
		if toj.IsCode(err, "send_idempotency_conflict") {
			return 0, "already_sent_with_other_text", nil
		}
		return 0, "toj_rejected_" + codeOf(err), nil
	}
	b.Stats.TojSends.Add(1)
	if res.Duplicate {
		b.Stats.TojDuplicateAcks.Add(1)
	}
	if err := b.reach(faults.AfterTojSend); err != nil {
		return 0, "", err
	}
	return res.MsgID, "sent", nil
}

func (b *Bridge) slackEdit(ctx context.Context, e store.PendingEvent, pair Pair, ev messageEvent) error {
	m := ev.Message
	if m == nil || m.Edited == nil {
		return b.ignore(ctx, e, "not_an_edit") // unfurls and attachment changes also arrive here
	}
	if echo, err := b.isEcho(ctx, pair.SlackChannel, m); err != nil || echo {
		if err != nil {
			return err
		}
		return b.finishEvent(ctx, e, "echo", nil)
	}
	mapping, err := store.MappingBySlack(ctx, b.Store.DB, pair.SlackChannel, m.TS)
	if errors.Is(err, store.ErrNotFound) {
		// The edit was delivered before the message it edits. It carries the whole current
		// message, so the copy is created from it; the late original is then skipped.
		name, err := b.slackUserName(ctx, *m)
		if err != nil {
			return err
		}
		msgID, outcome, err := b.sendToToj(ctx, pair, m.TS, TojTextForSlackMessage(name, m.Text))
		if err != nil || msgID == 0 {
			if err != nil {
				return err
			}
			return b.finishEvent(ctx, e, outcome, nil)
		}
		return b.finishEvent(ctx, e, "sent_from_edit", func(tx *sql.Tx) error {
			return store.InsertSlackOriginEdited(ctx, tx, pair.SlackChannel, m.TS, pair.TojDialog, msgID, 0, m.Edited.TS)
		})
	}
	if err != nil {
		return err
	}
	if mapping.Deleted {
		return b.finishEvent(ctx, e, "tombstoned", nil)
	}
	if mapping.Origin == "toj" {
		if !b.Controls.DisableLoopGuard {
			b.Stats.SlackEchoesByTS.Add(1)
			return b.finishEvent(ctx, e, "echo", nil)
		}
		return b.ignore(ctx, e, "edit_of_bridge_post")
	}
	if slack.CompareTS(m.Edited.TS, mapping.SlackEditTS) <= 0 {
		b.Stats.StaleEditsDropped.Add(1)
		return b.finishEvent(ctx, e, "stale_edit", nil)
	}
	name, err := b.slackUserName(ctx, *m)
	if err != nil {
		return err
	}
	text := TojTextForSlackMessage(name, m.Text)
	expected := mapping.TojEditVersion
	for tries := 0; tries < 5; tries++ {
		res, err := b.Toj.Edit(ctx, pair.TojDialog, mapping.TojMsgID, slackEditID(pair.SlackChannel, m.TS, m.Edited.TS, expected), text, expected)
		switch {
		case err == nil:
			b.Stats.TojEdits.Add(1)
			return b.finishEvent(ctx, e, "edited", func(tx *sql.Tx) error {
				return store.SetTojEditVersion(ctx, tx, mapping.ID, res.Message.EditVersion, m.Edited.TS)
			})
		case toj.IsCode(err, "edit_conflict"):
			// Only the bridge edits its copy, so the stored version is behind (a crash after the
			// server committed). The newest Slack edit wins: retry on the current version.
			var tojErr *toj.Error
			errors.As(err, &tojErr)
			if tojErr.CurrentEditVersion == nil {
				return b.finishEvent(ctx, e, "edit_conflict_without_version", nil)
			}
			b.Stats.TojEditConflicts.Add(1)
			expected = *tojErr.CurrentEditVersion
		case toj.IsCode(err, "message_expired"):
			return b.finishEvent(ctx, e, "target_deleted", func(tx *sql.Tx) error { return store.MarkDeleted(ctx, tx, mapping.ID) })
		case toj.Retryable(err):
			return fmt.Errorf("%w: toj edit: %v", errTransient, err)
		default:
			return b.finishEvent(ctx, e, "toj_rejected_"+codeOf(err), nil)
		}
	}
	return fmt.Errorf("%w: toj edit kept conflicting", errTransient)
}

func (b *Bridge) slackDelete(ctx context.Context, e store.PendingEvent, pair Pair, ev messageEvent) error {
	if echo, err := b.isEcho(ctx, pair.SlackChannel, ev.PreviousMessage); err != nil || echo {
		if err != nil {
			return err
		}
		return b.finishEvent(ctx, e, "echo", nil)
	}
	mapping, err := store.MappingBySlack(ctx, b.Store.DB, pair.SlackChannel, ev.DeletedTS)
	if errors.Is(err, store.ErrNotFound) {
		b.Stats.TombstonesWritten.Add(1)
		return b.finishEvent(ctx, e, "tombstone", func(tx *sql.Tx) error {
			return store.InsertSlackTombstone(ctx, tx, pair.SlackChannel, ev.DeletedTS, pair.TojDialog)
		})
	}
	if err != nil {
		return err
	}
	if mapping.Origin == "toj" && !b.Controls.DisableLoopGuard {
		b.Stats.SlackEchoesByTS.Add(1)
		return b.finishEvent(ctx, e, "echo", nil)
	}
	if mapping.Deleted || mapping.TojMsgID == 0 {
		return b.finishEvent(ctx, e, "already_deleted", nil)
	}
	_, err = b.Toj.Delete(ctx, pair.TojDialog, mapping.TojMsgID, slackDeleteID(pair.SlackChannel, ev.DeletedTS))
	if err != nil && !toj.IsCode(err, "message_expired") {
		if toj.Retryable(err) {
			return fmt.Errorf("%w: toj delete: %v", errTransient, err)
		}
		return b.finishEvent(ctx, e, "toj_rejected_"+codeOf(err), nil)
	}
	b.Stats.TojDeletes.Add(1)
	return b.finishEvent(ctx, e, "deleted", func(tx *sql.Tx) error { return store.MarkDeleted(ctx, tx, mapping.ID) })
}

func (b *Bridge) slackUserName(ctx context.Context, m slack.Message) (string, error) {
	if m.User == "" {
		if m.Username != "" {
			return m.Username, nil
		}
		return "Slack bot", nil
	}
	b.namesMu.Lock()
	name, ok := b.slackName[m.User]
	b.namesMu.Unlock()
	if ok {
		return name, nil
	}
	name, err := b.Slack.UserName(ctx, m.User)
	if err != nil {
		var apiErr *slack.APIError
		if errors.As(err, &apiErr) {
			name = m.User
		} else {
			return "", fmt.Errorf("%w: users.info: %v", errTransient, err)
		}
	}
	b.namesMu.Lock()
	b.slackName[m.User] = name
	b.namesMu.Unlock()
	return name, nil
}

func codeOf(err error) string {
	var tojErr *toj.Error
	if errors.As(err, &tojErr) {
		if tojErr.Code != "" {
			return tojErr.Code
		}
		return strconv.Itoa(tojErr.Status)
	}
	return "unknown"
}
