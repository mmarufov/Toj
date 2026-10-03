package slack

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type Counter = atomic.Int64

// MetadataEventType tags every post the bridge makes. The payload names the Toj message, so a
// post can be found in channel history after a crash and recognised if it is ever echoed back.
const MetadataEventType = "toj_bridge_mirror"

type Metadata struct {
	EventType    string          `json:"event_type"`
	EventPayload MetadataPayload `json:"event_payload"`
}

type MetadataPayload struct {
	TojDialog string `json:"toj_dialog"`
	TojMsgID  int64  `json:"toj_msg_id"`
}

// Message is the subset of a Slack message object the bridge reads, from events and history.
type Message struct {
	Type     string    `json:"type"`
	Subtype  string    `json:"subtype"`
	User     string    `json:"user"`
	BotID    string    `json:"bot_id"`
	AppID    string    `json:"app_id"`
	Text     string    `json:"text"`
	TS       string    `json:"ts"`
	ThreadTS string    `json:"thread_ts"`
	Edited   *Edited   `json:"edited"`
	Metadata *Metadata `json:"metadata"`
	Username string    `json:"username"`
}

type Edited struct {
	User string `json:"user"`
	TS   string `json:"ts"`
}

// RateLimitedError is a 429. RetryAfter comes from the Retry-After header.
type RateLimitedError struct{ RetryAfter time.Duration }

func (e *RateLimitedError) Error() string {
	return fmt.Sprintf("slack rate limited, retry after %s", e.RetryAfter)
}

// APIError is an ok:false answer. The request reached Slack and was refused, so the outcome is
// known.
type APIError struct{ Code string }

func (e *APIError) Error() string { return "slack api error: " + e.Code }

func IsAPIError(err error, code string) bool {
	var apiErr *APIError
	return errors.As(err, &apiErr) && apiErr.Code == code
}

type Client struct {
	BaseURL string // https://slack.com/api
	Token   string
	HTTP    *http.Client
	Calls   Counter
}

func NewClient(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *Client) call(ctx context.Context, method string, jsonBody any, form url.Values, out any) error {
	c.Calls.Add(1)
	var req *http.Request
	var err error
	if jsonBody != nil {
		raw, marshalErr := json.Marshal(jsonBody)
		if marshalErr != nil {
			return marshalErr
		}
		req, err = http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/"+method, bytes.NewReader(raw))
		if err == nil {
			req.Header.Set("Content-Type", "application/json; charset=utf-8")
		}
	} else {
		req, err = http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+"/"+method, strings.NewReader(form.Encode()))
		if err == nil {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		}
	}
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		seconds, _ := strconv.Atoi(resp.Header.Get("Retry-After"))
		if seconds < 1 {
			seconds = 1
		}
		return &RateLimitedError{RetryAfter: time.Duration(seconds) * time.Second}
	}
	if resp.StatusCode >= 500 {
		return fmt.Errorf("slack %s: http %d", method, resp.StatusCode)
	}
	var status struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &status); err != nil {
		return fmt.Errorf("slack %s: decode: %w", method, err)
	}
	if !status.OK {
		if status.Error == "ratelimited" || status.Error == "rate_limited" {
			return &RateLimitedError{RetryAfter: time.Second}
		}
		return &APIError{Code: status.Error}
	}
	if out != nil {
		return json.Unmarshal(body, out)
	}
	return nil
}

type PostParams struct {
	Channel  string
	Text     string
	Username string
	Metadata *Metadata
}

func (c *Client) PostMessage(ctx context.Context, p PostParams) (string, error) {
	body := map[string]any{"channel": p.Channel, "text": p.Text, "unfurl_links": false, "unfurl_media": false}
	if p.Username != "" {
		body["username"] = p.Username
	}
	if p.Metadata != nil {
		body["metadata"] = p.Metadata
	}
	var out struct {
		TS string `json:"ts"`
	}
	if err := c.call(ctx, "chat.postMessage", body, nil, &out); err != nil {
		return "", err
	}
	return out.TS, nil
}

func (c *Client) UpdateMessage(ctx context.Context, channel, ts, text string) error {
	return c.call(ctx, "chat.update", map[string]any{"channel": channel, "ts": ts, "text": text}, nil, nil)
}

func (c *Client) DeleteMessage(ctx context.Context, channel, ts string) error {
	return c.call(ctx, "chat.delete", map[string]any{"channel": channel, "ts": ts}, nil, nil)
}

type HistoryPage struct {
	Messages         []Message `json:"messages"`
	HasMore          bool      `json:"has_more"`
	ResponseMetadata struct {
		NextCursor string `json:"next_cursor"`
	} `json:"response_metadata"`
}

// History lists messages newer than oldest, with metadata, following cursors.
func (c *Client) History(ctx context.Context, channel, oldest string) ([]Message, error) {
	var all []Message
	cursor := ""
	for {
		form := url.Values{"channel": {channel}, "oldest": {oldest}, "inclusive": {"true"},
			"limit": {"200"}, "include_all_metadata": {"true"}}
		if cursor != "" {
			form.Set("cursor", cursor)
		}
		var page HistoryPage
		if err := c.call(ctx, "conversations.history", nil, form, &page); err != nil {
			return nil, err
		}
		all = append(all, page.Messages...)
		cursor = page.ResponseMetadata.NextCursor
		if !page.HasMore || cursor == "" {
			return all, nil
		}
	}
}

type Identity struct {
	UserID string `json:"user_id"`
	BotID  string `json:"bot_id"`
	TeamID string `json:"team_id"`
}

func (c *Client) AuthTest(ctx context.Context) (Identity, error) {
	var out Identity
	err := c.call(ctx, "auth.test", nil, url.Values{}, &out)
	return out, err
}

func (c *Client) UserName(ctx context.Context, userID string) (string, error) {
	var out struct {
		User struct {
			Name    string `json:"name"`
			Profile struct {
				DisplayName string `json:"display_name"`
				RealName    string `json:"real_name"`
			} `json:"profile"`
		} `json:"user"`
	}
	if err := c.call(ctx, "users.info", nil, url.Values{"user": {userID}}, &out); err != nil {
		return "", err
	}
	for _, name := range []string{out.User.Profile.DisplayName, out.User.Profile.RealName, out.User.Name} {
		if name != "" {
			return name, nil
		}
	}
	return userID, nil
}
