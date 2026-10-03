// Package store is the bridge's only durable state: one SQLite file holding the message map, the
// outbound intents to Slack, the Slack events already received, the Toj cursor and the Toj
// session. Every decision that must survive a kill -9 is a row here.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS toj_session (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  account_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  -- Set before a refresh request is sent and cleared once its answer is stored. A retry after a
  -- crash re-sends the same (refresh_token, rotation_id) pair, which the server answers from its
  -- receipt. A fresh rotation id with an already-used refresh token is reuse, and the server
  -- revokes the session.
  pending_rotation_id TEXT
);

CREATE TABLE IF NOT EXISTS toj_cursor (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  pts INTEGER NOT NULL
);

-- Durable inbox for the Slack Events API. A row is written before the 200 is returned, so an
-- acknowledged event is never lost to a crash: the worker drains pending rows on restart.
--
-- Row absence decides whether a delivery is processed. A pruned event_id that Slack re-delivers
-- is processed again. Slack's last retry comes about 5 minutes after the first delivery, and
-- EventRetention is 24 hours, so a pruned row cannot meet a Slack retry. If one ever did, the
-- Toj send is keyed by clientMsgId = UUIDv5(channel, ts), which the server deduplicates for 90
-- days, and edits are keyed by clientMutationId, whose 24-hour receipt then answers 409 and never
-- re-runs. Re-processing is therefore benign, not destructive.
CREATE TABLE IF NOT EXISTS slack_events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  received_at INTEGER NOT NULL,
  payload BLOB,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done')),
  outcome TEXT
);
CREATE INDEX IF NOT EXISTS slack_events_pending ON slack_events (status, seq);

-- One row per mirrored message. origin says which side the human wrote on; the other side's copy
-- is authored by the bridge.
CREATE TABLE IF NOT EXISTS message_map (
  id INTEGER PRIMARY KEY,
  origin TEXT NOT NULL CHECK (origin IN ('toj', 'slack')),
  toj_dialog TEXT NOT NULL,
  toj_msg_id INTEGER,
  slack_channel TEXT NOT NULL,
  slack_ts TEXT,
  -- slack origin: edit_version of the bridge's Toj copy. toj origin: last Toj edit mirrored.
  toj_edit_version INTEGER NOT NULL DEFAULT 0,
  -- slack origin: the edited.ts of the last Slack edit applied, so an older edit delivered late
  -- cannot overwrite a newer one.
  slack_edit_ts TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  UNIQUE (toj_dialog, toj_msg_id),
  UNIQUE (slack_channel, slack_ts)
);

-- Toj-to-Slack work. chat.postMessage has no idempotency key, so the intent is written first
-- (in the same transaction that advances the Toj cursor), attempts is incremented before each
-- request, and an intent with attempts > 0 is reconciled against channel history before any
-- repost.
CREATE TABLE IF NOT EXISTS outbound_intents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slack_channel TEXT NOT NULL,
  toj_dialog TEXT NOT NULL,
  toj_msg_id INTEGER NOT NULL,
  op TEXT NOT NULL CHECK (op IN ('post', 'update', 'delete')),
  text TEXT,
  username TEXT,
  toj_edit_version INTEGER NOT NULL DEFAULT 0,
  attempts INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'skipped')),
  outcome TEXT,
  created_at INTEGER NOT NULL,
  done_at INTEGER
);
CREATE INDEX IF NOT EXISTS outbound_intents_pending ON outbound_intents (status, slack_channel, id);
`

// EventRetention is how long a processed Slack event id is kept for deduplication.
const EventRetention = 24 * time.Hour

var ErrNotFound = errors.New("not found")

type Store struct {
	DB *sql.DB
}

// Open opens or creates the SQLite file. WAL lets the events handler insert while the workers
// write, and busy_timeout keeps a short lock wait from failing the 3-second ack.
func Open(path string) (*Store, error) {
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=synchronous(FULL)&_pragma=foreign_keys(ON)", path)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One writer at a time is SQLite's model; a single connection makes BEGIN IMMEDIATE ordering
	// explicit instead of surfacing SQLITE_BUSY under load.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &Store{DB: db}, nil
}

func (s *Store) Close() error { return s.DB.Close() }

// Tx runs fn in one transaction.
func (s *Store) Tx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	return tx.Commit()
}

// Session

type Session struct {
	AccountID, DeviceID, AccessToken, RefreshToken string
	PendingRotationID                              string
}

func (s *Store) LoadSession(ctx context.Context) (Session, error) {
	var out Session
	var pending sql.NullString
	err := s.DB.QueryRowContext(ctx, `SELECT account_id, device_id, access_token, refresh_token, pending_rotation_id FROM toj_session WHERE id = 1`).
		Scan(&out.AccountID, &out.DeviceID, &out.AccessToken, &out.RefreshToken, &pending)
	if errors.Is(err, sql.ErrNoRows) {
		return out, ErrNotFound
	}
	out.PendingRotationID = pending.String
	return out, err
}

func (s *Store) SaveSession(ctx context.Context, v Session) error {
	_, err := s.DB.ExecContext(ctx, `
INSERT INTO toj_session (id, account_id, device_id, access_token, refresh_token, pending_rotation_id)
VALUES (1, ?, ?, ?, ?, NULLIF(?, ''))
ON CONFLICT (id) DO UPDATE SET account_id = excluded.account_id, device_id = excluded.device_id,
  access_token = excluded.access_token, refresh_token = excluded.refresh_token,
  pending_rotation_id = excluded.pending_rotation_id`,
		v.AccountID, v.DeviceID, v.AccessToken, v.RefreshToken, v.PendingRotationID)
	return err
}

// Cursor

func (s *Store) Cursor(ctx context.Context) (int64, bool, error) {
	var pts int64
	err := s.DB.QueryRowContext(ctx, `SELECT pts FROM toj_cursor WHERE id = 1`).Scan(&pts)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return pts, err == nil, err
}

func SetCursor(ctx context.Context, tx *sql.Tx, pts int64) error {
	_, err := tx.ExecContext(ctx, `
INSERT INTO toj_cursor (id, pts) VALUES (1, ?)
ON CONFLICT (id) DO UPDATE SET pts = excluded.pts WHERE excluded.pts > toj_cursor.pts`, pts)
	return err
}

// Slack events

// InsertEvent records a delivery. It reports false when the event id was already recorded, which
// is how Slack retries and duplicate deliveries are absorbed.
func (s *Store) InsertEvent(ctx context.Context, eventID string, payload []byte, now time.Time) (bool, error) {
	res, err := s.DB.ExecContext(ctx, `
INSERT INTO slack_events (event_id, received_at, payload) VALUES (?, ?, ?)
ON CONFLICT (event_id) DO NOTHING`, eventID, now.UnixMilli(), payload)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

// InsertEventAlways is the negative control for deduplication: every delivery gets its own row.
func (s *Store) InsertEventAlways(ctx context.Context, eventID string, payload []byte, now time.Time) error {
	_, err := s.DB.ExecContext(ctx, `
INSERT INTO slack_events (event_id, received_at, payload) VALUES (?, ?, ?)`,
		fmt.Sprintf("%s#%d", eventID, now.UnixNano()), now.UnixMilli(), payload)
	return err
}

type PendingEvent struct {
	Seq     int64
	EventID string
	Payload []byte
}

func (s *Store) PendingEvents(ctx context.Context, limit int) ([]PendingEvent, error) {
	rows, err := s.DB.QueryContext(ctx, `
SELECT seq, event_id, payload FROM slack_events WHERE status = 'pending' ORDER BY seq LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PendingEvent
	for rows.Next() {
		var e PendingEvent
		if err := rows.Scan(&e.Seq, &e.EventID, &e.Payload); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// FinishEvent marks an event processed and drops its payload, so message text is not kept once
// it has been mirrored.
func FinishEvent(ctx context.Context, tx *sql.Tx, seq int64, outcome string) error {
	_, err := tx.ExecContext(ctx, `UPDATE slack_events SET status = 'done', outcome = ?, payload = NULL WHERE seq = ?`, outcome, seq)
	return err
}

// PruneEvents deletes processed event ids older than EventRetention. Pending rows are never
// pruned: they are acknowledged work that has not run yet.
func (s *Store) PruneEvents(ctx context.Context, now time.Time) (int64, error) {
	res, err := s.DB.ExecContext(ctx, `DELETE FROM slack_events WHERE status = 'done' AND received_at < ?`,
		now.Add(-EventRetention).UnixMilli())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// Message map

type Mapping struct {
	ID             int64
	Origin         string
	TojDialog      string
	TojMsgID       int64
	SlackChannel   string
	SlackTS        string
	TojEditVersion int64
	SlackEditTS    string
	Deleted        bool
}

const mappingColumns = `id, origin, toj_dialog, COALESCE(toj_msg_id, 0), slack_channel, COALESCE(slack_ts, ''), toj_edit_version, COALESCE(slack_edit_ts, ''), deleted`

type querier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func scanMapping(row *sql.Row) (Mapping, error) {
	var m Mapping
	var deleted int
	err := row.Scan(&m.ID, &m.Origin, &m.TojDialog, &m.TojMsgID, &m.SlackChannel, &m.SlackTS, &m.TojEditVersion, &m.SlackEditTS, &deleted)
	if errors.Is(err, sql.ErrNoRows) {
		return m, ErrNotFound
	}
	m.Deleted = deleted != 0
	return m, err
}

func MappingBySlack(ctx context.Context, q querier, channel, ts string) (Mapping, error) {
	return scanMapping(q.QueryRowContext(ctx, `SELECT `+mappingColumns+` FROM message_map WHERE slack_channel = ? AND slack_ts = ?`, channel, ts))
}

func MappingByToj(ctx context.Context, q querier, dialog string, msgID int64) (Mapping, error) {
	return scanMapping(q.QueryRowContext(ctx, `SELECT `+mappingColumns+` FROM message_map WHERE toj_dialog = ? AND toj_msg_id = ?`, dialog, msgID))
}

// InsertSlackOrigin records a Slack message and its Toj copy once the Toj send is acknowledged.
func InsertSlackOrigin(ctx context.Context, tx *sql.Tx, channel, ts, dialog string, msgID, editVersion int64) error {
	_, err := tx.ExecContext(ctx, `
INSERT INTO message_map (origin, toj_dialog, toj_msg_id, slack_channel, slack_ts, toj_edit_version)
VALUES ('slack', ?, ?, ?, ?, ?)
ON CONFLICT (slack_channel, slack_ts) DO NOTHING`, dialog, msgID, channel, ts, editVersion)
	return err
}

// InsertTojOrigin records a Toj message whose Slack copy has not been posted yet.
func InsertTojOrigin(ctx context.Context, tx *sql.Tx, dialog string, msgID int64, channel string) (bool, error) {
	res, err := tx.ExecContext(ctx, `
INSERT INTO message_map (origin, toj_dialog, toj_msg_id, slack_channel)
VALUES ('toj', ?, ?, ?)
ON CONFLICT (toj_dialog, toj_msg_id) DO NOTHING`, dialog, msgID, channel)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n == 1, err
}

func SetSlackTS(ctx context.Context, tx *sql.Tx, dialog string, msgID int64, ts string) error {
	_, err := tx.ExecContext(ctx, `UPDATE message_map SET slack_ts = ? WHERE toj_dialog = ? AND toj_msg_id = ?`, ts, dialog, msgID)
	return err
}

func SetTojEditVersion(ctx context.Context, tx *sql.Tx, id, version int64, slackEditTS string) error {
	_, err := tx.ExecContext(ctx, `
UPDATE message_map SET toj_edit_version = MAX(toj_edit_version, ?),
  slack_edit_ts = CASE WHEN ? = '' THEN slack_edit_ts ELSE ? END
WHERE id = ?`, version, slackEditTS, slackEditTS, id)
	return err
}

func MarkDeleted(ctx context.Context, tx *sql.Tx, id int64) error {
	_, err := tx.ExecContext(ctx, `UPDATE message_map SET deleted = 1 WHERE id = ?`, id)
	return err
}

// IsBridgePost reports whether a Slack ts is a post the bridge made (a Toj-origin mapping).
func (s *Store) IsBridgePost(ctx context.Context, channel, ts string) (bool, error) {
	var one int
	err := s.DB.QueryRowContext(ctx, `SELECT 1 FROM message_map WHERE origin = 'toj' AND slack_channel = ? AND slack_ts = ?`, channel, ts).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

// Outbound intents

type Intent struct {
	ID             int64
	SlackChannel   string
	TojDialog      string
	TojMsgID       int64
	Op             string
	Text           string
	Username       string
	TojEditVersion int64
	Attempts       int
	CreatedAt      time.Time
}

func InsertIntent(ctx context.Context, tx *sql.Tx, in Intent, now time.Time) error {
	_, err := tx.ExecContext(ctx, `
INSERT INTO outbound_intents (slack_channel, toj_dialog, toj_msg_id, op, text, username, toj_edit_version, created_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		in.SlackChannel, in.TojDialog, in.TojMsgID, in.Op, in.Text, in.Username, in.TojEditVersion, now.UnixMilli())
	return err
}

// NextIntent returns the oldest pending intent for a channel. Intents for one channel run strictly
// in order, which keeps Slack's order equal to Toj's and keeps an update behind its post.
func (s *Store) NextIntent(ctx context.Context, channel string) (Intent, error) {
	var in Intent
	var created int64
	var text, username sql.NullString
	err := s.DB.QueryRowContext(ctx, `
SELECT id, slack_channel, toj_dialog, toj_msg_id, op, text, username, toj_edit_version, attempts, created_at
FROM outbound_intents WHERE status = 'pending' AND slack_channel = ? ORDER BY id LIMIT 1`, channel).
		Scan(&in.ID, &in.SlackChannel, &in.TojDialog, &in.TojMsgID, &in.Op, &text, &username, &in.TojEditVersion, &in.Attempts, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return in, ErrNotFound
	}
	in.Text, in.Username = text.String, username.String
	in.CreatedAt = time.UnixMilli(created)
	return in, err
}

func (s *Store) PendingIntentChannels(ctx context.Context) ([]string, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT DISTINCT slack_channel FROM outbound_intents WHERE status = 'pending'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// BeginAttempt is committed before the Slack request leaves, so after a crash the bridge knows the
// request may have reached Slack.
func (s *Store) BeginAttempt(ctx context.Context, id int64) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE outbound_intents SET attempts = attempts + 1 WHERE id = ?`, id)
	return err
}

func FinishIntent(ctx context.Context, tx *sql.Tx, id int64, status, outcome string, now time.Time) error {
	_, err := tx.ExecContext(ctx, `
UPDATE outbound_intents SET status = ?, outcome = ?, text = NULL, done_at = ? WHERE id = ?`,
		status, outcome, now.UnixMilli(), id)
	return err
}

// UndoAttempt is for an attempt Slack refused outright (429 or ok:false): nothing was posted, so
// the next try needs no reconcile.
func (s *Store) UndoAttempt(ctx context.Context, id int64) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE outbound_intents SET attempts = MAX(attempts - 1, 0) WHERE id = ?`, id)
	return err
}

// InsertSlackTombstone records a Slack message deleted before its creation was processed, so the
// late creation event is not mirrored.
func InsertSlackTombstone(ctx context.Context, tx *sql.Tx, channel, ts, dialog string) error {
	_, err := tx.ExecContext(ctx, `
INSERT INTO message_map (origin, toj_dialog, slack_channel, slack_ts, deleted)
VALUES ('slack', ?, ?, ?, 1)
ON CONFLICT (slack_channel, slack_ts) DO UPDATE SET deleted = 1`, dialog, channel, ts)
	return err
}

// InsertSlackOriginEdited is InsertSlackOrigin for a copy created from an edit event.
func InsertSlackOriginEdited(ctx context.Context, tx *sql.Tx, channel, ts, dialog string, msgID, editVersion int64, editTS string) error {
	_, err := tx.ExecContext(ctx, `
INSERT INTO message_map (origin, toj_dialog, toj_msg_id, slack_channel, slack_ts, toj_edit_version, slack_edit_ts)
VALUES ('slack', ?, ?, ?, ?, ?, NULLIF(?, ''))
ON CONFLICT (slack_channel, slack_ts) DO NOTHING`, dialog, msgID, channel, ts, editVersion, editTS)
	return err
}
