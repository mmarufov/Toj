// Package slackfake is a Slack stand-in for tests and the chaos driver. It serves the Web API
// methods the bridge calls and delivers signed Events API requests to the bridge, and it can
// inject what real Slack does on a bad day: retries with the real headers, duplicate deliveries,
// reordering, acknowledgements that arrive too late, 429s with Retry-After, and replies lost
// after the write committed.
//
// Everything it measures is simulated Slack, and is labelled that way wherever it is reported.
package slackfake

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
)

type Config struct {
	SigningSecret string
	BotToken      string
	BotID         string
	BotUserID     string
	AppID         string
	// EventsURL is the bridge's Events endpoint. Empty means events are only recorded.
	EventsURL string
	Seed      uint64

	// RetrySchedule is the delay before retry 1, 2 and 3. Slack's is about 0 s, 1 min and 5 min.
	RetrySchedule []time.Duration
	AckTimeout    time.Duration // Slack's is 3 s
	// Concurrent deliveries in flight.
	Concurrency int

	PDuplicate            float64       // a second, independent delivery of the same event
	ReorderJitter         time.Duration // random delay before each event's first delivery
	PSlowAck              float64       // treat a 200 as a timeout and retry anyway
	PRateLimit            float64       // answer a channel call with 429
	RetryAfter            time.Duration // Retry-After on injected 429s
	PDropReply            float64       // commit a write, then close the connection with no reply
	EventsIncludeMetadata bool          // whether message events carry metadata (unconfirmed for real Slack)
}

type Msg struct {
	TS        string          `json:"ts"`
	User      string          `json:"user,omitempty"`
	BotID     string          `json:"bot_id,omitempty"`
	AppID     string          `json:"app_id,omitempty"`
	Username  string          `json:"username,omitempty"`
	Text      string          `json:"text"`
	Edited    *slack.Edited   `json:"edited,omitempty"`
	Metadata  *slack.Metadata `json:"metadata,omitempty"`
	Deleted   bool            `json:"-"`
	CreatedAt time.Time       `json:"-"`
}

type Stats struct {
	EventsCreated      int
	Deliveries         int // every POST to the bridge, first attempts, retries and duplicates
	RetryDeliveries    int
	RetriesByReason    map[string]int
	DuplicatesInjected int
	SlowAcksInjected   int
	Undeliverable      int // event deliveries whose last retry also failed, as Slack sees it
	// UndeliverableUnseen is the subset where no attempt got a 2xx from the bridge. The rest were
	// answered by the bridge, and only the fake's injected late ack made Slack count them failed.
	UndeliverableUnseen int
	NonOKAcks           int
	AckLatencies        []time.Duration // per delivery that got an HTTP answer
	RateLimited         int             // injected 429s
	RateLimitViolations int             // calls for a channel while its Retry-After was running
	RepliesDropped      int
	APICalls            map[string]int
	BotPosts            int
	HistoryCalls        int
}

type Fake struct {
	cfg    Config
	server *http.Server
	ln     net.Listener
	client *http.Client

	mu        sync.Mutex
	rng       *rand.Rand
	channels  map[string]map[string]*Msg
	lastTS    time.Time
	blocked   map[string]time.Time
	stats     Stats
	users     map[string]string
	nextEvent int
	sem       chan struct{}
	wg        sync.WaitGroup
	stopping  bool
	pending   int
}

func New(cfg Config) *Fake {
	if cfg.AckTimeout == 0 {
		cfg.AckTimeout = 3 * time.Second
	}
	if cfg.RetrySchedule == nil {
		cfg.RetrySchedule = []time.Duration{0, time.Minute, 5 * time.Minute}
	}
	if cfg.Concurrency == 0 {
		cfg.Concurrency = 8
	}
	if cfg.RetryAfter == 0 {
		cfg.RetryAfter = time.Second
	}
	f := &Fake{
		cfg:      cfg,
		rng:      rand.New(rand.NewPCG(cfg.Seed, cfg.Seed^0x5eed)),
		channels: map[string]map[string]*Msg{},
		blocked:  map[string]time.Time{},
		users:    map[string]string{},
		sem:      make(chan struct{}, cfg.Concurrency),
		stats:    Stats{RetriesByReason: map[string]int{}, APICalls: map[string]int{}},
		client:   &http.Client{Timeout: cfg.AckTimeout, Transport: &http.Transport{DisableKeepAlives: true}},
	}
	return f
}

// Start serves the Web API on addr ("127.0.0.1:0" for any port) and returns its base URL.
func (f *Fake) Start(addr string) (string, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return "", err
	}
	f.ln = ln
	mux := http.NewServeMux()
	mux.HandleFunc("/api/", f.serveAPI)
	f.server = &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go f.server.Serve(ln)
	return "http://" + ln.Addr().String() + "/api", nil
}

func (f *Fake) Close() {
	f.mu.Lock()
	f.stopping = true
	f.mu.Unlock()
	if f.server != nil {
		f.server.Close()
	}
}

func (f *Fake) SetEventsURL(url string) {
	f.mu.Lock()
	f.cfg.EventsURL = url
	f.mu.Unlock()
}

func (f *Fake) AddUser(id, name string) {
	f.mu.Lock()
	f.users[id] = name
	f.mu.Unlock()
}

func (f *Fake) Stats() Stats {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.stats
	out.RetriesByReason = map[string]int{}
	for k, v := range f.stats.RetriesByReason {
		out.RetriesByReason[k] = v
	}
	out.APICalls = map[string]int{}
	for k, v := range f.stats.APICalls {
		out.APICalls[k] = v
	}
	out.AckLatencies = append([]time.Duration(nil), f.stats.AckLatencies...)
	return out
}

// PendingDeliveries is the number of events still being delivered or waiting for a retry.
func (f *Fake) PendingDeliveries() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pending
}

// Messages returns a channel's messages in ts order, deleted ones included.
func (f *Fake) Messages(channel string) []Msg {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []Msg
	for _, m := range f.channels[channel] {
		out = append(out, *m)
	}
	sort.Slice(out, func(i, j int) bool { return slack.CompareTS(out[i].TS, out[j].TS) < 0 })
	return out
}

// nextTS returns a ts strictly greater than every earlier one. Caller holds mu.
func (f *Fake) nextTS() (string, time.Time) {
	now := time.Now()
	if !now.After(f.lastTS) {
		now = f.lastTS.Add(time.Microsecond)
	}
	f.lastTS = now
	return fmt.Sprintf("%d.%06d", now.Unix(), now.Nanosecond()/1000), now
}

func (f *Fake) channel(id string) map[string]*Msg {
	ch := f.channels[id]
	if ch == nil {
		ch = map[string]*Msg{}
		f.channels[id] = ch
	}
	return ch
}

// Human actions. These are what a person does in the Slack client.

func (f *Fake) HumanPost(channel, user, text string) string {
	f.mu.Lock()
	ts, now := f.nextTS()
	m := &Msg{TS: ts, User: user, Text: text, CreatedAt: now}
	f.channel(channel)[ts] = m
	event := map[string]any{"type": "message", "channel": channel, "user": user, "text": text, "ts": ts, "event_ts": ts}
	f.mu.Unlock()
	f.emit(event)
	return ts
}

func (f *Fake) HumanEdit(channel, ts, user, text string) bool {
	f.mu.Lock()
	m := f.channel(channel)[ts]
	if m == nil || m.Deleted || m.User != user {
		f.mu.Unlock()
		return false
	}
	previous := *m
	editTS, _ := f.nextTS()
	m.Text = text
	m.Edited = &slack.Edited{User: user, TS: editTS}
	event := f.changedEvent(channel, editTS, *m, previous)
	f.mu.Unlock()
	f.emit(event)
	return true
}

func (f *Fake) HumanDelete(channel, ts, user string) bool {
	f.mu.Lock()
	m := f.channel(channel)[ts]
	if m == nil || m.Deleted || m.User != user {
		f.mu.Unlock()
		return false
	}
	m.Deleted = true
	eventTS, _ := f.nextTS()
	event := f.deletedEvent(channel, eventTS, *m)
	f.mu.Unlock()
	f.emit(event)
	return true
}

func (f *Fake) messageJSON(m Msg) map[string]any {
	out := map[string]any{"type": "message", "ts": m.TS, "text": m.Text}
	if m.User != "" {
		out["user"] = m.User
	}
	if m.BotID != "" {
		out["bot_id"], out["app_id"], out["subtype"] = m.BotID, m.AppID, "bot_message"
	}
	if m.Username != "" {
		out["username"] = m.Username
	}
	if m.Edited != nil {
		out["edited"] = m.Edited
	}
	if m.Metadata != nil && f.cfg.EventsIncludeMetadata {
		out["metadata"] = m.Metadata
	}
	return out
}

func (f *Fake) changedEvent(channel, eventTS string, current, previous Msg) map[string]any {
	return map[string]any{"type": "message", "subtype": "message_changed", "hidden": true, "channel": channel,
		"ts": eventTS, "event_ts": eventTS, "message": f.messageJSON(current), "previous_message": f.messageJSON(previous)}
}

func (f *Fake) deletedEvent(channel, eventTS string, m Msg) map[string]any {
	return map[string]any{"type": "message", "subtype": "message_deleted", "hidden": true, "channel": channel,
		"ts": eventTS, "event_ts": eventTS, "deleted_ts": m.TS, "previous_message": f.messageJSON(m)}
}

// Events API delivery

func (f *Fake) emit(event map[string]any) {
	f.mu.Lock()
	if f.stopping {
		f.mu.Unlock()
		return
	}
	f.nextEvent++
	id := fmt.Sprintf("Ev%08d", f.nextEvent)
	f.stats.EventsCreated++
	envelope, _ := json.Marshal(map[string]any{
		"token": "unused", "team_id": "T0FAKE", "api_app_id": f.cfg.AppID, "type": "event_callback",
		"event_id": id, "event_time": time.Now().Unix(), "event": event,
	})
	duplicate := f.rng.Float64() < f.cfg.PDuplicate
	jitter := time.Duration(0)
	if f.cfg.ReorderJitter > 0 {
		jitter = time.Duration(f.rng.Int64N(int64(f.cfg.ReorderJitter)))
	}
	if duplicate {
		f.stats.DuplicatesInjected++
	}
	f.pending++
	if duplicate {
		f.pending++
	}
	f.mu.Unlock()
	f.wg.Add(1)
	go f.deliver(envelope, jitter)
	if duplicate {
		f.wg.Add(1)
		go f.deliver(envelope, jitter+time.Duration(f.randInt(int64(50*time.Millisecond))))
	}
}

func (f *Fake) randInt(n int64) int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	if n <= 0 {
		return 0
	}
	return f.rng.Int64N(n)
}

func (f *Fake) chance(p float64) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.rng.Float64() < p
}

// deliver sends one event with Slack's retry rules: up to 3 retries, each with X-Slack-Retry-Num
// and X-Slack-Retry-Reason, after the configured delays.
func (f *Fake) deliver(envelope []byte, firstDelay time.Duration) {
	defer f.wg.Done()
	defer func() {
		f.mu.Lock()
		f.pending--
		f.mu.Unlock()
	}()
	time.Sleep(firstDelay)
	reason := ""
	reached := false
	for attempt := 0; attempt <= len(f.cfg.RetrySchedule); attempt++ {
		if attempt > 0 {
			time.Sleep(f.cfg.RetrySchedule[attempt-1])
		}
		f.mu.Lock()
		stopping, url := f.stopping, f.cfg.EventsURL
		f.mu.Unlock()
		if stopping || url == "" {
			return
		}
		ok, answered, why := f.attempt(url, envelope, attempt, reason)
		if ok {
			return
		}
		reached = reached || answered
		reason = why
	}
	f.mu.Lock()
	f.stats.Undeliverable++
	if !reached {
		f.stats.UndeliverableUnseen++
	}
	f.mu.Unlock()
}

// attempt reports whether Slack counts the delivery as done, and whether the bridge answered 2xx.
func (f *Fake) attempt(url string, envelope []byte, retryNum int, reason string) (bool, bool, string) {
	f.sem <- struct{}{}
	defer func() { <-f.sem }()
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(envelope))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Slack-Request-Timestamp", ts)
	req.Header.Set("X-Slack-Signature", slack.Sign([]byte(f.cfg.SigningSecret), ts, envelope))
	if retryNum > 0 {
		req.Header.Set("X-Slack-Retry-Num", strconv.Itoa(retryNum))
		req.Header.Set("X-Slack-Retry-Reason", reason)
	}
	started := time.Now()
	resp, err := f.client.Do(req)
	elapsed := time.Since(started)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stats.Deliveries++
	if retryNum > 0 {
		f.stats.RetryDeliveries++
		f.stats.RetriesByReason[reason]++
	}
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return false, false, "http_timeout"
		}
		return false, false, "connection_failed"
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	f.stats.AckLatencies = append(f.stats.AckLatencies, elapsed)
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		f.stats.NonOKAcks++
		return false, false, "http_error"
	}
	if f.rng.Float64() < f.cfg.PSlowAck {
		f.stats.SlowAcksInjected++
		return false, true, "http_timeout"
	}
	return true, true, ""
}

// Drain waits until every event has been delivered or given up on.
func (f *Fake) Drain(ctx context.Context) error {
	for {
		if f.PendingDeliveries() == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

// Web API

func (f *Fake) serveAPI(w http.ResponseWriter, r *http.Request) {
	method := strings.TrimPrefix(r.URL.Path, "/api/")
	if r.Header.Get("Authorization") != "Bearer "+f.cfg.BotToken {
		writeJSON(w, map[string]any{"ok": false, "error": "invalid_auth"})
		return
	}
	params := map[string]any{}
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		json.NewDecoder(r.Body).Decode(&params)
	} else {
		r.ParseForm()
		for k := range r.PostForm {
			params[k] = r.PostForm.Get(k)
		}
	}
	str := func(k string) string { s, _ := params[k].(string); return s }
	channel := str("channel")

	f.mu.Lock()
	f.stats.APICalls[method]++
	if channel != "" {
		if until, ok := f.blocked[channel]; ok && time.Now().Before(until) {
			f.stats.RateLimitViolations++
			f.mu.Unlock()
			w.Header().Set("Retry-After", strconv.Itoa(int((time.Until(until)+time.Second-1)/time.Second)))
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		if method != "conversations.history" && f.rng.Float64() < f.cfg.PRateLimit {
			f.stats.RateLimited++
			f.blocked[channel] = time.Now().Add(f.cfg.RetryAfter)
			f.mu.Unlock()
			w.Header().Set("Retry-After", strconv.Itoa(int(f.cfg.RetryAfter/time.Second)))
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
	}
	dropReply := (method == "chat.postMessage" || method == "chat.update" || method == "chat.delete") &&
		f.rng.Float64() < f.cfg.PDropReply
	var result map[string]any
	var event map[string]any
	switch method {
	case "auth.test":
		result = map[string]any{"ok": true, "user_id": f.cfg.BotUserID, "bot_id": f.cfg.BotID, "team_id": "T0FAKE"}
	case "users.info":
		name, ok := f.users[str("user")]
		if !ok {
			result = map[string]any{"ok": false, "error": "user_not_found"}
		} else {
			result = map[string]any{"ok": true, "user": map[string]any{"id": str("user"), "name": name,
				"profile": map[string]any{"display_name": name}}}
		}
	case "chat.postMessage":
		ts, now := f.nextTS()
		m := &Msg{TS: ts, BotID: f.cfg.BotID, AppID: f.cfg.AppID, Username: str("username"), Text: str("text"), CreatedAt: now}
		if raw, ok := params["metadata"]; ok {
			b, _ := json.Marshal(raw)
			var md slack.Metadata
			if json.Unmarshal(b, &md) == nil && md.EventType != "" {
				m.Metadata = &md
			}
		}
		f.channel(channel)[ts] = m
		f.stats.BotPosts++
		event = map[string]any{"channel": channel, "event_ts": ts}
		for k, v := range f.messageJSON(*m) {
			event[k] = v
		}
		result = map[string]any{"ok": true, "channel": channel, "ts": ts}
	case "chat.update":
		m := f.channel(channel)[str("ts")]
		switch {
		case m == nil || m.Deleted:
			result = map[string]any{"ok": false, "error": "message_not_found"}
		case m.BotID != f.cfg.BotID:
			result = map[string]any{"ok": false, "error": "cant_update_message"}
		default:
			previous := *m
			editTS, _ := f.nextTS()
			m.Text = str("text")
			m.Edited = &slack.Edited{User: f.cfg.BotUserID, TS: editTS}
			event = f.changedEvent(channel, editTS, *m, previous)
			result = map[string]any{"ok": true, "channel": channel, "ts": m.TS}
		}
	case "chat.delete":
		m := f.channel(channel)[str("ts")]
		switch {
		case m == nil || m.Deleted:
			result = map[string]any{"ok": false, "error": "message_not_found"}
		case m.BotID != f.cfg.BotID:
			result = map[string]any{"ok": false, "error": "cant_delete_message"}
		default:
			m.Deleted = true
			eventTS, _ := f.nextTS()
			event = f.deletedEvent(channel, eventTS, *m)
			result = map[string]any{"ok": true, "channel": channel, "ts": m.TS}
		}
	case "conversations.history":
		f.stats.HistoryCalls++
		result = f.history(channel, str("oldest"), str("include_all_metadata") == "true", str("cursor"), str("limit"))
	default:
		result = map[string]any{"ok": false, "error": "unknown_method"}
	}
	if dropReply && result["ok"] == true {
		f.stats.RepliesDropped++
	}
	f.mu.Unlock()
	if event != nil {
		f.emit(event)
	}
	if dropReply && result["ok"] == true {
		// The write is committed and its event is out; the caller never learns the ts.
		if hj, ok := w.(http.Hijacker); ok {
			if conn, _, err := hj.Hijack(); err == nil {
				conn.Close()
				return
			}
		}
	}
	writeJSON(w, result)
}

// history returns live messages newer than oldest, newest first, as Slack does. Caller holds mu.
func (f *Fake) history(channel, oldest string, withMetadata bool, cursor, limitParam string) map[string]any {
	var live []*Msg
	for _, m := range f.channel(channel) {
		if !m.Deleted && slack.CompareTS(m.TS, oldest) >= 0 {
			live = append(live, m)
		}
	}
	sort.Slice(live, func(i, j int) bool { return slack.CompareTS(live[i].TS, live[j].TS) > 0 })
	limit, _ := strconv.Atoi(limitParam)
	if limit <= 0 || limit > 999 {
		limit = 100
	}
	offset, _ := strconv.Atoi(cursor)
	end := min(offset+limit, len(live))
	if offset > len(live) {
		offset = len(live)
	}
	var page []map[string]any
	for _, m := range live[offset:end] {
		j := map[string]any{"type": "message", "ts": m.TS, "text": m.Text}
		if m.User != "" {
			j["user"] = m.User
		}
		if m.BotID != "" {
			j["bot_id"], j["app_id"] = m.BotID, m.AppID
		}
		if m.Edited != nil {
			j["edited"] = m.Edited
		}
		if withMetadata && m.Metadata != nil {
			j["metadata"] = m.Metadata
		}
		page = append(page, j)
	}
	next := ""
	if end < len(live) {
		next = strconv.Itoa(end)
	}
	return map[string]any{"ok": true, "messages": page, "has_more": next != "",
		"response_metadata": map[string]any{"next_cursor": next}}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}
