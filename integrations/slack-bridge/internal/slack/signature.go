package slack

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"strconv"
	"time"
)

// MaxSignatureAge is the replay window Slack documents for request signatures.
const MaxSignatureAge = 5 * time.Minute

var (
	ErrMissingSignature = errors.New("missing slack signature headers")
	ErrStaleSignature   = errors.New("slack request timestamp outside the 5 minute window")
	ErrBadSignature     = errors.New("slack signature mismatch")
)

// Sign returns the v0 signature for a body sent at timestamp ts.
func Sign(secret []byte, ts string, body []byte) string {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte("v0:" + ts + ":"))
	mac.Write(body)
	return "v0=" + hex.EncodeToString(mac.Sum(nil))
}

// Verify checks X-Slack-Signature over v0:{X-Slack-Request-Timestamp}:{raw body}. The body must be
// the exact bytes received, before any JSON decoding.
func Verify(secret []byte, header http.Header, body []byte, now time.Time) error {
	ts := header.Get("X-Slack-Request-Timestamp")
	sig := header.Get("X-Slack-Signature")
	if ts == "" || sig == "" {
		return ErrMissingSignature
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return ErrMissingSignature
	}
	age := now.Sub(time.Unix(sec, 0))
	if age > MaxSignatureAge || age < -MaxSignatureAge {
		return ErrStaleSignature
	}
	if !hmac.Equal([]byte(Sign(secret, ts, body)), []byte(sig)) {
		return ErrBadSignature
	}
	return nil
}
