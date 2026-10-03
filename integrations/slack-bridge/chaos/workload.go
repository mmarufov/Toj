package main

import (
	"context"
	"fmt"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slackfake"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

// source is one message a human wrote, with what the driver did to it.
type source struct {
	Origin    string // "toj" or "slack"
	Token     string
	Author    string // Toj account id or Slack user id
	TojMsgID  int64
	SlackTS   string
	Text      string // final text as written by the author (Slack text is Slack-escaped)
	Edits     int
	Deleted   bool
	CreatedAt time.Time // Toj: send acknowledged; Slack: fake created it
}

type human struct {
	name   string
	client *toj.Client
}

type workload struct {
	mu      sync.Mutex
	sources []*source
	errors  []string
}

func (w *workload) add(s *source) {
	w.mu.Lock()
	w.sources = append(w.sources, s)
	w.mu.Unlock()
}

func (w *workload) fail(format string, args ...any) {
	w.mu.Lock()
	w.errors = append(w.errors, fmt.Sprintf(format, args...))
	w.mu.Unlock()
}

// text returns a message body. The token makes every message attributable; about one in five
// carries characters Slack escapes.
func text(rng *rand.Rand, token, suffix string) string {
	body := token + " " + suffix
	if rng.IntN(5) == 0 {
		body += " & <check>"
	}
	return body
}

func slackEscape(s string) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '&':
			out = append(out, "&amp;"...)
		case '<':
			out = append(out, "&lt;"...)
		case '>':
			out = append(out, "&gt;"...)
		default:
			out = append(out, s[i])
		}
	}
	return string(out)
}

// retry runs fn until it succeeds or ctx ends. The humans' traffic goes straight to the server,
// not through Toxiproxy, but the server can still be busy.
func retry(ctx context.Context, fn func() error) error {
	var err error
	for attempt := 0; ctx.Err() == nil && attempt < 50; attempt++ {
		if err = fn(); err == nil || !toj.Retryable(err) {
			return err
		}
		time.Sleep(100 * time.Millisecond)
	}
	return err
}

type plan struct {
	edits   int
	deleted bool
	delays  [3]time.Duration
}

func planFor(rng *rand.Rand) plan {
	p := plan{}
	if rng.Float64() < 0.15 {
		p.edits = 1
		if rng.Float64() < 0.05/0.15 {
			p.edits = 2
		}
	}
	p.deleted = rng.Float64() < 0.05
	for i := range p.delays {
		p.delays[i] = time.Duration(rng.Int64N(int64(2 * time.Second)))
	}
	return p
}

// run sends n messages (half per side) spaced by gap, and schedules each message's edits and
// deletes. It returns when every action has been performed.
func (w *workload) run(ctx context.Context, rng *rand.Rand, n int, gap time.Duration,
	humans []human, fake *slackfake.Fake, channel, dialog, runTag string) {
	var wg sync.WaitGroup
	slackUsers := []string{"U0ALICE", "U0BOB"}
	for i := 0; i < n; i++ {
		if ctx.Err() != nil {
			break
		}
		token := fmt.Sprintf("tk%s%04d%s", runTag, i, uuid.NewString()[:6])
		p := planFor(rng)
		body := text(rng, token, fmt.Sprintf("message %d", i))
		if i%2 == 0 {
			h := humans[(i/2)%len(humans)]
			s := &source{Origin: "toj", Token: token, Author: h.client.Session().AccountID, Text: body}
			var res toj.SendResult
			clientMsgID := uuid.NewString()
			if err := retry(ctx, func() (err error) {
				res, err = h.client.Send(ctx, dialog, clientMsgID, body)
				return err
			}); err != nil {
				w.fail("toj send %s: %v", token, err)
				continue
			}
			s.TojMsgID, s.CreatedAt = res.MsgID, time.Now()
			w.add(s)
			wg.Add(1)
			go func() {
				defer wg.Done()
				w.mutateToj(ctx, rng.Uint64(), h, dialog, s, p)
			}()
		} else {
			user := slackUsers[(i/2)%len(slackUsers)]
			escaped := slackEscape(body)
			s := &source{Origin: "slack", Token: token, Author: user, Text: escaped}
			s.CreatedAt = time.Now()
			s.SlackTS = fake.HumanPost(channel, user, escaped)
			w.add(s)
			seed := rng.Uint64()
			wg.Add(1)
			go func() {
				defer wg.Done()
				w.mutateSlack(ctx, seed, fake, channel, s, p)
			}()
		}
		time.Sleep(gap)
	}
	wg.Wait()
}

func (w *workload) mutateToj(ctx context.Context, seed uint64, h human, dialog string, s *source, p plan) {
	rng := rand.New(rand.NewPCG(seed, seed^1))
	version := int64(0)
	for e := 0; e < p.edits; e++ {
		time.Sleep(p.delays[e])
		body := text(rng, s.Token, fmt.Sprintf("edit %d", e+1))
		mutationID := uuid.NewString()
		if err := retry(ctx, func() error {
			_, err := h.client.Edit(ctx, dialog, s.TojMsgID, mutationID, body, version)
			return err
		}); err != nil {
			w.fail("toj edit %s: %v", s.Token, err)
			return
		}
		version++
		w.mu.Lock()
		s.Text, s.Edits = body, s.Edits+1
		w.mu.Unlock()
	}
	if p.deleted {
		time.Sleep(p.delays[2])
		mutationID := uuid.NewString()
		if err := retry(ctx, func() error {
			_, err := h.client.Delete(ctx, dialog, s.TojMsgID, mutationID)
			return err
		}); err != nil {
			w.fail("toj delete %s: %v", s.Token, err)
			return
		}
		w.mu.Lock()
		s.Deleted = true
		w.mu.Unlock()
	}
}

func (w *workload) mutateSlack(ctx context.Context, seed uint64, fake *slackfake.Fake, channel string, s *source, p plan) {
	rng := rand.New(rand.NewPCG(seed, seed^1))
	for e := 0; e < p.edits; e++ {
		time.Sleep(p.delays[e])
		body := slackEscape(text(rng, s.Token, fmt.Sprintf("edit %d", e+1)))
		if !fake.HumanEdit(channel, s.SlackTS, s.Author, body) {
			w.fail("slack edit %s refused", s.Token)
			return
		}
		w.mu.Lock()
		s.Text, s.Edits = body, s.Edits+1
		w.mu.Unlock()
	}
	if p.deleted {
		time.Sleep(p.delays[2])
		if !fake.HumanDelete(channel, s.SlackTS, s.Author) {
			w.fail("slack delete %s refused", s.Token)
			return
		}
		w.mu.Lock()
		s.Deleted = true
		w.mu.Unlock()
	}
}
