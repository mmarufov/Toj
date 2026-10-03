package slack

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
)

func newHandler(t *testing.T, controls faults.Controls) (*EventsHandler, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "events.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return &EventsHandler{Secret: []byte("s3cret"), Store: st, Wake: make(chan struct{}, 1),
		Controls: controls, Log: slog.New(slog.NewTextHandler(io.Discard, nil)), Stats: &HandlerStats{}}, st
}

func deliver(h http.Handler, body []byte, retry string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/slack/events", bytes.NewReader(body))
	for k, v := range signed("s3cret", time.Now(), body) {
		req.Header[k] = v
	}
	if retry != "" {
		req.Header.Set("X-Slack-Retry-Num", retry)
		req.Header.Set("X-Slack-Retry-Reason", "http_timeout")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func pending(t *testing.T, st *store.Store) int {
	events, err := st.PendingEvents(context.Background(), 100)
	if err != nil {
		t.Fatal(err)
	}
	return len(events)
}

func TestURLVerificationEchoesTheChallenge(t *testing.T) {
	h, _ := newHandler(t, faults.Controls{})
	rec := deliver(h, []byte(`{"type":"url_verification","challenge":"abc123"}`), "")
	if rec.Code != 200 || rec.Body.String() != "abc123" {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestEventIsStoredBeforeTheAckAndRetriesAreAbsorbed(t *testing.T) {
	h, st := newHandler(t, faults.Controls{})
	body := []byte(`{"type":"event_callback","event_id":"Ev1","event":{"type":"message"}}`)
	for _, retry := range []string{"", "1", "2", "3"} {
		if rec := deliver(h, body, retry); rec.Code != 200 {
			t.Fatalf("retry %q answered %d", retry, rec.Code)
		}
	}
	if n := pending(t, st); n != 1 {
		t.Fatalf("stored %d events, want 1", n)
	}
	if h.Stats.Duplicates.Load() != 3 {
		t.Fatalf("duplicates = %d, want 3", h.Stats.Duplicates.Load())
	}
}

// Negative control: without the event_id check every retry is stored as new work.
func TestEventDedupeOffStoresEveryRetry(t *testing.T) {
	h, st := newHandler(t, faults.Controls{DisableEventDedupe: true})
	body := []byte(`{"type":"event_callback","event_id":"Ev1","event":{"type":"message"}}`)
	for _, retry := range []string{"", "1", "2"} {
		deliver(h, body, retry)
	}
	if n := pending(t, st); n != 3 {
		t.Fatalf("stored %d events, want 3", n)
	}
}

func TestBadSignatureIsRejectedAndNotStored(t *testing.T) {
	h, st := newHandler(t, faults.Controls{})
	body := []byte(`{"type":"event_callback","event_id":"Ev1","event":{}}`)
	req := httptest.NewRequest(http.MethodPost, "/slack/events", bytes.NewReader(body))
	for k, v := range signed("wrong", time.Now(), body) {
		req.Header[k] = v
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized || pending(t, st) != 0 {
		t.Fatalf("got %d with %d stored", rec.Code, pending(t, st))
	}
}
