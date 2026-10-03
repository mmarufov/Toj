package slack

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
)

// MaxEventBytes bounds a request body. Slack message events are a few kilobytes.
const MaxEventBytes = 1 << 20

// Envelope is the outer Events API body.
type Envelope struct {
	Type      string          `json:"type"`
	Challenge string          `json:"challenge"`
	APIAppID  string          `json:"api_app_id"`
	EventID   string          `json:"event_id"`
	EventTime int64           `json:"event_time"`
	Event     json.RawMessage `json:"event"`
}

// EventsHandler verifies a delivery, stores it, and answers 200. Everything slow happens later in
// the worker, which the handler only wakes. The store insert is the only work between reading the
// body and acknowledging, so the 3-second deadline is spent on one local SQLite write.
type EventsHandler struct {
	Secret   []byte
	Store    *store.Store
	Wake     chan<- struct{}
	Controls faults.Controls
	Now      func() time.Time
	Log      *slog.Logger
	// Stats is optional; the counters are read by tests and the chaos driver.
	Stats *HandlerStats
}

type HandlerStats struct {
	Accepted, Duplicates, Rejected Counter
}

func (h *EventsHandler) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}

func (h *EventsHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, MaxEventBytes+1))
	if err != nil || len(body) > MaxEventBytes {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err := Verify(h.Secret, r.Header, body, h.now()); err != nil {
		h.count(func(s *HandlerStats) { s.Rejected.Add(1) })
		// 401 tells Slack this is not ours; nothing about which check failed goes back.
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var env Envelope
	if err := json.Unmarshal(body, &env); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	switch env.Type {
	case "url_verification":
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, env.Challenge)
		return
	case "event_callback":
	default:
		w.WriteHeader(http.StatusOK)
		return
	}
	if env.EventID == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// The insert must finish even if Slack hangs up, or an event could be acknowledged by a
	// retry that then finds a half-written state. A short detached deadline keeps it bounded.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 2*time.Second)
	defer cancel()
	if h.Controls.DisableEventDedupe {
		err = h.Store.InsertEventAlways(ctx, env.EventID, body, h.now())
	} else {
		var inserted bool
		inserted, err = h.Store.InsertEvent(ctx, env.EventID, body, h.now())
		if err == nil && !inserted {
			h.count(func(s *HandlerStats) { s.Duplicates.Add(1) })
			w.WriteHeader(http.StatusOK)
			return
		}
	}
	if err != nil {
		h.Log.Error("store slack event", "err", err)
		// A 5xx makes Slack retry, which is what we want when nothing was stored.
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	h.count(func(s *HandlerStats) { s.Accepted.Add(1) })
	w.WriteHeader(http.StatusOK)
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	faults.Reach(faults.AfterEventAck)
	select {
	case h.Wake <- struct{}{}:
	default:
	}
}

func (h *EventsHandler) count(fn func(*HandlerStats)) {
	if h.Stats != nil {
		fn(h.Stats)
	}
}
