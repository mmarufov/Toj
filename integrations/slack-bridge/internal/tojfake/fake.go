// Package tojfake is an in-memory Toj server for the bridge's unit tests. It implements only what
// the bridge calls, with the server's idempotency rules: sends keyed by (sender, clientMsgId),
// mutations keyed by (actor, clientMutationId), optimistic edits answered with 409 edit_conflict,
// per-account pts, and refresh rotation with replayable receipts. The chaos driver uses the real
// server instead.
package tojfake

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"time"
)

type Message struct {
	DialogID        string `json:"dialog_id"`
	MsgID           int64  `json:"msg_id"`
	SenderAccountID string `json:"sender_account_id"`
	ClientMsgID     string `json:"client_msg_id"`
	Kind            string `json:"kind"`
	Text            string `json:"text"`
	EditVersion     int64  `json:"edit_version"`
	State           string `json:"state"`
	ServerTS        string `json:"server_ts"`
}

type event struct {
	pts      int64
	typ      string
	dialogID string
	msgID    int64
}

type receipt struct {
	fingerprint string
	result      map[string]any
}

type Fake struct {
	Server *httptest.Server

	mu          sync.Mutex
	tokens      map[string]string         // access token -> account
	refresh     map[string]string         // live refresh token -> account
	usedRefresh map[string]string         // retired refresh token -> account
	rotations   map[string]map[string]any // refresh token + rotation id -> response
	members     map[string][]string
	messages    map[string][]*Message
	sends       map[string]*Message // account|clientMsgId -> message
	sendBodies  map[string]string
	mutations   map[string]receipt
	events      map[string][]event
	names       map[string]string
	n           int
	// FailNext makes the next n requests to a path answer 503 before doing anything.
	FailNext map[string]int
	// Revoked is set when a refresh token is reused with a new rotation id.
	Revoked map[string]bool
}

func New() *Fake {
	f := &Fake{
		tokens: map[string]string{}, refresh: map[string]string{}, usedRefresh: map[string]string{},
		rotations: map[string]map[string]any{}, members: map[string][]string{},
		messages: map[string][]*Message{}, sends: map[string]*Message{}, sendBodies: map[string]string{},
		mutations: map[string]receipt{}, events: map[string][]event{}, names: map[string]string{},
		FailNext: map[string]int{}, Revoked: map[string]bool{},
	}
	f.Server = httptest.NewServer(http.HandlerFunc(f.serve))
	return f
}

func (f *Fake) Close() { f.Server.Close() }

func (f *Fake) id(prefix string) string {
	f.n++
	return fmt.Sprintf("%s-%04d", prefix, f.n)
}

// Account creates an account and returns its id, access token and refresh token.
func (f *Fake) Account(name string) (id, access, refresh string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	id = f.id("acct")
	access, refresh = f.id("access"), f.id("refresh")
	f.tokens[access] = id
	f.refresh[refresh] = id
	f.names[id] = name
	return
}

// ExpireAccess makes an access token answer 401 access_token_expired.
func (f *Fake) ExpireAccess(token string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tokens[token] = "expired"
}

func (f *Fake) Group(members ...string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	d := f.id("dialog")
	f.members[d] = members
	return d
}

func (f *Fake) Messages(dialog string) []Message {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []Message
	for _, m := range f.messages[dialog] {
		out = append(out, *m)
	}
	return out
}

// fanout appends one event to every member's log. Caller holds mu.
func (f *Fake) fanout(dialog, typ string, msgID int64) int64 {
	var actorPts int64
	for _, a := range f.members[dialog] {
		pts := int64(len(f.events[a]) + 1)
		f.events[a] = append(f.events[a], event{pts: pts, typ: typ, dialogID: dialog, msgID: msgID})
		actorPts = pts
	}
	return actorPts
}

// Send is a human sending a message directly, outside the bridge.
func (f *Fake) Send(account, dialog, clientMsgID, body string) int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.send(account, dialog, clientMsgID, body)["msgId"].(int64)
}

func (f *Fake) send(account, dialog, clientMsgID, body string) map[string]any {
	key := account + "|" + clientMsgID
	if m, ok := f.sends[key]; ok {
		if f.sendBodies[key] != body {
			return map[string]any{"status": 409, "code": "send_idempotency_conflict"}
		}
		return map[string]any{"msgId": m.MsgID, "duplicate": true}
	}
	m := &Message{DialogID: dialog, MsgID: int64(len(f.messages[dialog]) + 1), SenderAccountID: account,
		ClientMsgID: clientMsgID, Kind: "text", Text: body, State: "visible", ServerTS: time.Now().UTC().Format(time.RFC3339Nano)}
	f.messages[dialog] = append(f.messages[dialog], m)
	f.sends[key], f.sendBodies[key] = m, body
	f.fanout(dialog, "message.new", m.MsgID)
	return map[string]any{"msgId": m.MsgID, "duplicate": false}
}

// Edit and Delete are a human changing their own message directly.
func (f *Fake) Edit(account, dialog string, msgID int64, body string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	m := f.messages[dialog][msgID-1]
	f.mutate(account, dialog, msgID, f.id("mut"), "edit", body, m.EditVersion)
}

func (f *Fake) Delete(account, dialog string, msgID int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mutate(account, dialog, msgID, f.id("mut"), "delete", "", 0)
}

func (f *Fake) mutate(account, dialog string, msgID int64, mutationID, op, body string, expected int64) map[string]any {
	key := account + "|" + mutationID
	fp := fmt.Sprintf("%s|%s|%d|%s|%d", op, dialog, msgID, body, expected)
	if r, ok := f.mutations[key]; ok {
		if r.fingerprint != fp {
			return map[string]any{"status": 409, "code": "idempotency_conflict"}
		}
		out := map[string]any{"duplicate": true, "message": *f.messages[dialog][msgID-1]}
		return out
	}
	if msgID < 1 || int(msgID) > len(f.messages[dialog]) {
		return map[string]any{"status": 400, "code": "invalid_sync_request"}
	}
	m := f.messages[dialog][msgID-1]
	if m.SenderAccountID != account {
		return map[string]any{"status": 400, "code": "invalid_sync_request"}
	}
	if m.State != "visible" {
		return map[string]any{"status": 409, "code": "message_expired"}
	}
	if op == "edit" {
		if m.EditVersion != expected {
			return map[string]any{"status": 409, "code": "edit_conflict", "currentEditVersion": m.EditVersion}
		}
		m.Text, m.EditVersion = body, m.EditVersion+1
		f.fanout(dialog, "message.edited", msgID)
	} else {
		m.Text, m.State = "", "deleted_for_all"
		f.fanout(dialog, "message.deleted", msgID)
	}
	f.mutations[key] = receipt{fingerprint: fp}
	return map[string]any{"duplicate": false, "message": *m}
}

func (f *Fake) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.FailNext[r.URL.Path] > 0 {
		f.FailNext[r.URL.Path]--
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	var body map[string]any
	json.NewDecoder(r.Body).Decode(&body)
	str := func(k string) string { s, _ := body[k].(string); return s }
	num := func(k string) int64 { v, _ := body[k].(float64); return int64(v) }
	reply := func(out map[string]any) {
		status := http.StatusOK
		if s, ok := out["status"].(int); ok {
			status = s
			delete(out, "status")
			out["error"] = out["code"]
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(out)
	}
	if r.URL.Path == "/v1/session/refresh" {
		reply(f.refreshSession(str("refreshToken"), str("rotationId")))
		return
	}
	account := f.tokens[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
	if account == "expired" {
		reply(map[string]any{"status": 401, "code": "access_token_expired"})
		return
	}
	if account == "" {
		reply(map[string]any{"status": 401, "code": "unauthorized"})
		return
	}
	switch r.URL.Path {
	case "/v1/sync/state":
		reply(map[string]any{"pts": int64(len(f.events[account]))})
	case "/v1/sync/difference":
		reply(f.difference(account, num("sincePts"), num("maxEvents")))
	case "/v1/messages/send":
		reply(f.send(account, str("dialogId"), str("clientMsgId"), str("body")))
	case "/v1/messages/edit":
		reply(f.mutate(account, str("dialogId"), num("msgId"), str("clientMutationId"), "edit", str("body"), num("expectedEditVersion")))
	case "/v1/messages/delete":
		reply(f.mutate(account, str("dialogId"), num("msgId"), str("clientMutationId"), "delete", "", 0))
	default:
		reply(map[string]any{"status": 404, "code": "not_found"})
	}
}

func (f *Fake) difference(account string, since, maxEvents int64) map[string]any {
	if maxEvents <= 0 || maxEvents > 200 {
		maxEvents = 200
	}
	log := f.events[account]
	var updates []map[string]any
	pts := since
	profiles := map[string]bool{}
	for _, e := range log {
		if e.pts <= since {
			continue
		}
		if int64(len(updates)) >= maxEvents {
			break
		}
		m := *f.messages[e.dialogID][e.msgID-1]
		profiles[m.SenderAccountID] = true
		updates = append(updates, map[string]any{"pts": e.pts, "type": e.typ, "dialog_id": e.dialogID, "message": m})
		pts = e.pts
	}
	kind := "difference"
	if pts < int64(len(log)) {
		kind = "difference_slice"
	}
	var profileList []map[string]any
	for id := range profiles {
		profileList = append(profileList, map[string]any{"accountId": id, "displayName": f.names[id]})
	}
	return map[string]any{"kind": kind, "state": map[string]any{"pts": pts}, "updates": updates, "profiles": profileList}
}

func (f *Fake) refreshSession(token, rotation string) map[string]any {
	if out, ok := f.rotations[token+"|"+rotation]; ok {
		return out // a retry of a rotation that already happened gets the same answer
	}
	account, live := f.refresh[token]
	if !live {
		if acct, used := f.usedRefresh[token]; used {
			f.Revoked[acct] = true
			for t, a := range f.tokens {
				if a == acct {
					delete(f.tokens, t)
				}
			}
			for t, a := range f.refresh {
				if a == acct {
					delete(f.refresh, t)
				}
			}
			return map[string]any{"status": 401, "code": "refresh_reuse_detected"}
		}
		return map[string]any{"status": 401, "code": "device_revoked"}
	}
	delete(f.refresh, token)
	f.usedRefresh[token] = account
	access, next := f.id("access"), f.id("refresh")
	f.tokens[access] = account
	f.refresh[next] = account
	out := map[string]any{"accountId": account, "deviceId": "device-" + account, "accessToken": access, "refreshToken": next}
	f.rotations[token+"|"+rotation] = out
	return out
}
