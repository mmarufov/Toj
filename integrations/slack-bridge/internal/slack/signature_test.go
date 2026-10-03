package slack

import (
	"errors"
	"net/http"
	"strconv"
	"testing"
	"time"
)

func signed(secret string, ts time.Time, body []byte) http.Header {
	stamp := strconv.FormatInt(ts.Unix(), 10)
	return http.Header{
		"X-Slack-Request-Timestamp": {stamp},
		"X-Slack-Signature":         {Sign([]byte(secret), stamp, body)},
	}
}

// Slack's documented example: secret, timestamp and body from the request-signing guide.
func TestSignMatchesSlackDocumentedExample(t *testing.T) {
	body := []byte("token=xyzz0WbapA4vBCDEFasx0q6G&team_id=T1DC2JH3J&team_domain=testteamnow&channel_id=G8PSS9T3V&channel_name=foobar&user_id=U2CERLKJA&user_name=roadrunner&command=%2Fwebhook-collect&text=&response_url=https%3A%2F%2Fhooks.slack.com%2Fcommands%2FT1DC2JH3J%2F397700885554%2F96rGlfmibIGlgcZRskXaIFfN&trigger_id=398738663015.47445629121.803a0bc887a14d10d2c447fce8b6703c")
	got := Sign([]byte("8f742231b10e8888abcd99yyyzzz85a5"), "1531420618", body)
	want := "v0=a2114d57b48eac39b9ad189dd8316235a7b4a8d21a10bd27519666489c69b503"
	if got != want {
		t.Fatalf("Sign = %s, want %s", got, want)
	}
}

func TestVerify(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	body := []byte(`{"type":"event_callback"}`)
	cases := []struct {
		name   string
		header http.Header
		body   []byte
		want   error
	}{
		{"valid", signed("s3cret", now, body), body, nil},
		{"tampered body", signed("s3cret", now, body), []byte(`{"type":"event_callback "}`), ErrBadSignature},
		{"wrong secret", signed("other", now, body), body, ErrBadSignature},
		{"older than 5 minutes", signed("s3cret", now.Add(-5*time.Minute-time.Second), body), body, ErrStaleSignature},
		{"inside the window", signed("s3cret", now.Add(-4*time.Minute), body), body, nil},
		{"from the future", signed("s3cret", now.Add(6*time.Minute), body), body, ErrStaleSignature},
		{"missing headers", http.Header{}, body, ErrMissingSignature},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := Verify([]byte("s3cret"), tc.header, tc.body, now); !errors.Is(err, tc.want) {
				t.Fatalf("Verify = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestCompareTS(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1700000000.000100", "1700000000.000200", -1},
		{"1700000001.000000", "1700000000.999999", 1},
		{"1700000000.0001", "1700000000.000100", 0},
		{"", "1700000000.000100", -1},
	}
	for _, tc := range cases {
		if got := CompareTS(tc.a, tc.b); got != tc.want {
			t.Errorf("CompareTS(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}
