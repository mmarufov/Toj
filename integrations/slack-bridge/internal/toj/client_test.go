package toj

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/tojfake"
)

func setup(t *testing.T) (*tojfake.Fake, *store.Store, string, string) {
	t.Helper()
	fake := tojfake.New()
	t.Cleanup(fake.Close)
	account, access, refresh := fake.Account("Slack bridge")
	st, err := store.Open(filepath.Join(t.TempDir(), "toj.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.SaveSession(context.Background(), store.Session{AccountID: account, DeviceID: "d", AccessToken: access, RefreshToken: refresh}); err != nil {
		t.Fatal(err)
	}
	return fake, st, access, refresh
}

func TestExpiredAccessTokenRefreshesOnceAndRetries(t *testing.T) {
	fake, st, access, _ := setup(t)
	client := NewClient(fake.Server.URL, st)
	if err := client.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	fake.ExpireAccess(access)
	if _, err := client.State(context.Background()); err != nil {
		t.Fatalf("state after expiry: %v", err)
	}
	saved, _ := st.LoadSession(context.Background())
	if saved.AccessToken == access || saved.PendingRotationID != "" {
		t.Fatalf("session not rotated cleanly: %+v", saved)
	}
}

// A crash after the server rotated but before the answer was stored: the restart re-sends the
// stored (refresh token, rotation id) pair and gets the same answer from the server's receipt.
func TestRefreshInterruptedByACrashResumesWithTheSameRotationID(t *testing.T) {
	for _, keepRotationID := range []bool{true, false} {
		name := "same rotation id"
		if !keepRotationID {
			name = "control: fresh rotation id is refresh-token reuse"
		}
		t.Run(name, func(t *testing.T) {
			fake, st, _, refresh := setup(t)
			ctx := context.Background()
			saved, _ := st.LoadSession(ctx)
			saved.PendingRotationID = "11111111-1111-4111-8111-111111111111"
			st.SaveSession(ctx, saved)
			// The request that reached the server before the crash.
			probe := NewClient(fake.Server.URL, &MemorySessions{})
			if err := probe.once(ctx, "POST", "/v1/session/refresh", map[string]any{
				"refreshToken": refresh, "rotationId": saved.PendingRotationID,
			}, nil, false); err != nil {
				t.Fatal(err)
			}
			if !keepRotationID {
				saved.PendingRotationID = "22222222-2222-4222-8222-222222222222"
				st.SaveSession(ctx, saved)
			}
			client := NewClient(fake.Server.URL, st)
			err := client.Load(ctx)
			if keepRotationID {
				if err != nil {
					t.Fatalf("resume: %v", err)
				}
				if _, err := client.State(ctx); err != nil {
					t.Fatalf("session unusable after resume: %v", err)
				}
				if fake.Revoked[saved.AccountID] {
					t.Fatal("session was revoked")
				}
			} else if err == nil || !fake.Revoked[saved.AccountID] {
				t.Fatalf("control: expected reuse detection, got %v", err)
			}
		})
	}
}
