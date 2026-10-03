// Package toj is a Toj client for an ordinary signed-in account: v2 session with refresh rotation,
// a pts cursor paged through /v1/sync/difference, WebSocket hints, and idempotent send, edit and
// delete. It speaks the same public protocol as the iOS app and holds no message keys: default
// chats are cloud chats that the server decrypts.
package toj

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
)

// Error is a non-2xx answer from the Toj server.
type Error struct {
	Status  int
	Code    string
	Message string
	// CurrentEditVersion is set on 409 edit_conflict.
	CurrentEditVersion *int64
}

func (e *Error) Error() string {
	return fmt.Sprintf("toj %d %s: %s", e.Status, e.Code, e.Message)
}

// Retryable matches the app's rule: transport errors, 408, 425, 429 and 5xx.
func Retryable(err error) bool {
	var tojErr *Error
	if !errors.As(err, &tojErr) {
		return true
	}
	s := tojErr.Status
	return s == 408 || s == 425 || s == 429 || s >= 500
}

func IsCode(err error, code string) bool {
	var tojErr *Error
	return errors.As(err, &tojErr) && tojErr.Code == code
}

// SessionStore persists the session; *store.Store satisfies it.
type SessionStore interface {
	LoadSession(context.Context) (store.Session, error)
	SaveSession(context.Context, store.Session) error
}

type Client struct {
	BaseURL string
	HTTP    *http.Client
	Store   SessionStore

	mu      sync.Mutex
	session store.Session
	// refreshMu serializes refreshes so two requests that both see an expired token rotate once.
	refreshMu sync.Mutex
}

func NewClient(baseURL string, st SessionStore) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Store:   st,
		// Connections are reused: on a 300 ms link a new connection costs a round trip per request.
		// Go's transport re-sends a POST on a reused connection only when none of it was written,
		// so the server cannot have seen it. Any other loss surfaces as an error that the caller
		// retries with the same idempotency key.
		HTTP: &http.Client{
			Timeout: 20 * time.Second,
			Transport: &http.Transport{
				MaxIdleConnsPerHost: 4,
				IdleConnTimeout:     30 * time.Second,
			},
		},
	}
}

func (c *Client) Session() store.Session {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session
}

// Load reads the stored session. A pending rotation from a crash mid-refresh is finished first.
func (c *Client) Load(ctx context.Context) error {
	s, err := c.Store.LoadSession(ctx)
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.session = s
	c.mu.Unlock()
	if s.PendingRotationID != "" {
		return c.refresh(ctx, s.AccessToken)
	}
	return nil
}

type authSession struct {
	AccountID    string `json:"accountId"`
	DeviceID     string `json:"deviceId"`
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
}

// StartLogin asks for an OTP. Outside production the server returns the code, which the chaos
// driver uses; on a hosted server the code arrives out of band and is passed to CompleteLogin.
func (c *Client) StartLogin(ctx context.Context, phone string) (string, error) {
	var out struct {
		Code string `json:"code"`
	}
	err := c.do(ctx, http.MethodPost, "/v1/auth/start", map[string]any{"phone": phone}, &out, false)
	return out.Code, err
}

func (c *Client) CompleteLogin(ctx context.Context, phone, code, displayName string) error {
	var out struct {
		State   string      `json:"state"`
		Session authSession `json:"session"`
	}
	err := c.do(ctx, http.MethodPost, "/v1/auth/check", map[string]any{
		"phone": phone, "code": code, "platform": "desktop", "deviceName": "Slack bridge",
		"displayName": displayName, "authProtocolVersion": 2,
	}, &out, false)
	if err != nil {
		return err
	}
	if out.State != "authenticated" {
		return fmt.Errorf("toj login state %q: the bridge account must not have two-step verification", out.State)
	}
	return c.adopt(ctx, out.Session)
}

func (c *Client) adopt(ctx context.Context, s authSession) error {
	next := store.Session{AccountID: s.AccountID, DeviceID: s.DeviceID, AccessToken: s.AccessToken, RefreshToken: s.RefreshToken}
	if err := c.Store.SaveSession(ctx, next); err != nil {
		return err
	}
	c.mu.Lock()
	c.session = next
	c.mu.Unlock()
	return nil
}

// refresh rotates the session. The rotation id is stored before the request leaves; a retry
// after a lost answer or a crash re-sends the same pair and the server replays its receipt.
func (c *Client) refresh(ctx context.Context, expired string) error {
	c.refreshMu.Lock()
	defer c.refreshMu.Unlock()
	current := c.Session()
	if current.AccessToken != expired && current.PendingRotationID == "" {
		return nil // another caller already rotated
	}
	if current.PendingRotationID == "" {
		current.PendingRotationID = uuid.NewString()
		if err := c.Store.SaveSession(ctx, current); err != nil {
			return err
		}
		c.mu.Lock()
		c.session = current
		c.mu.Unlock()
	}
	var out authSession
	for attempt := 0; ; attempt++ {
		err := c.do(ctx, http.MethodPost, "/v1/session/refresh", map[string]any{
			"refreshToken": current.RefreshToken, "rotationId": current.PendingRotationID,
		}, &out, false)
		if err == nil {
			return c.adopt(ctx, out)
		}
		if !Retryable(err) {
			return fmt.Errorf("refresh session: %w", err)
		}
		if err := sleep(ctx, backoff(attempt)); err != nil {
			return err
		}
	}
}

// do sends one request. Authenticated requests refresh once on access_token_expired.
func (c *Client) do(ctx context.Context, method, path string, body, out any, authed bool) error {
	err := c.once(ctx, method, path, body, out, authed)
	if authed && IsCode(err, "access_token_expired") {
		if err := c.refresh(ctx, c.Session().AccessToken); err != nil {
			return err
		}
		err = c.once(ctx, method, path, body, out, authed)
	}
	return err
}

func (c *Client) once(ctx context.Context, method, path string, body, out any, authed bool) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if authed {
		req.Header.Set("Authorization", "Bearer "+c.Session().AccessToken)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		var e struct {
			Error              string `json:"error"`
			Code               string `json:"code"`
			CurrentEditVersion *int64 `json:"currentEditVersion"`
		}
		_ = json.Unmarshal(raw, &e)
		return &Error{Status: resp.StatusCode, Code: e.Code, Message: e.Error, CurrentEditVersion: e.CurrentEditVersion}
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			return fmt.Errorf("decode %s: %w", path, err)
		}
	}
	return nil
}

// Wire types

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

type Update struct {
	PTS      int64    `json:"pts"`
	Type     string   `json:"type"`
	DialogID string   `json:"dialog_id"`
	Message  *Message `json:"message"`
}

type Profile struct {
	AccountID   string `json:"accountId"`
	DisplayName string `json:"displayName"`
}

type Difference struct {
	Kind  string `json:"kind"`
	State struct {
		PTS int64 `json:"pts"`
	} `json:"state"`
	Updates  []Update  `json:"updates"`
	Profiles []Profile `json:"profiles"`
}

func (c *Client) State(ctx context.Context) (int64, error) {
	var out struct {
		PTS int64 `json:"pts"`
	}
	err := c.do(ctx, http.MethodGet, "/v1/sync/state", nil, &out, true)
	return out.PTS, err
}

func (c *Client) Difference(ctx context.Context, sincePts int64) (Difference, error) {
	var out Difference
	err := c.do(ctx, http.MethodPost, "/v1/sync/difference", map[string]any{"sincePts": sincePts, "maxEvents": 200}, &out, true)
	return out, err
}

type SendResult struct {
	MsgID     int64 `json:"msgId"`
	Duplicate bool  `json:"duplicate"`
}

func (c *Client) Send(ctx context.Context, dialogID, clientMsgID, body string) (SendResult, error) {
	var out SendResult
	err := c.do(ctx, http.MethodPost, "/v1/messages/send", map[string]any{
		"dialogId": dialogID, "clientMsgId": clientMsgID, "body": body,
	}, &out, true)
	return out, err
}

type MutationResult struct {
	Duplicate bool    `json:"duplicate"`
	Message   Message `json:"message"`
}

func (c *Client) Edit(ctx context.Context, dialogID string, msgID int64, mutationID, body string, expected int64) (MutationResult, error) {
	var out MutationResult
	err := c.do(ctx, http.MethodPost, "/v1/messages/edit", map[string]any{
		"dialogId": dialogID, "msgId": msgID, "clientMutationId": mutationID,
		"body": body, "expectedEditVersion": expected,
	}, &out, true)
	return out, err
}

func (c *Client) Delete(ctx context.Context, dialogID string, msgID int64, mutationID string) (MutationResult, error) {
	var out MutationResult
	err := c.do(ctx, http.MethodPost, "/v1/messages/delete", map[string]any{
		"dialogId": dialogID, "msgId": msgID, "clientMutationId": mutationID,
	}, &out, true)
	return out, err
}

func (c *Client) CreateGroup(ctx context.Context, groupID, title string, memberIDs []string) error {
	return c.do(ctx, http.MethodPost, "/v1/groups", map[string]any{
		"groupId": groupID, "title": title, "memberIds": memberIDs,
	}, nil, true)
}

func (c *Client) WebSocketURL() string {
	base := c.BaseURL
	if strings.HasPrefix(base, "https://") {
		return "wss://" + strings.TrimPrefix(base, "https://") + "/v1/ws"
	}
	return "ws://" + strings.TrimPrefix(base, "http://") + "/v1/ws"
}

func backoff(attempt int) time.Duration {
	base := 100 * time.Millisecond << min(attempt, 5)
	if base > 3*time.Second {
		base = 3 * time.Second
	}
	return base/2 + time.Duration(randInt64(int64(base/2)))
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
