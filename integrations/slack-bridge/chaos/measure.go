package main

import (
	"context"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/bridge"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slackfake"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

// tojView is the server's truth for one group, read by a human member straight from the server
// (not through Toxiproxy) with the same difference protocol.
type tojView struct {
	client *toj.Client
	dialog string
	pts    int64
	msgs   map[int64]*tojMsg
}

type tojMsg struct {
	toj.Message
	FirstServerTS time.Time
}

func newTojView(client *toj.Client, dialog string, pts int64) *tojView {
	return &tojView{client: client, dialog: dialog, pts: pts, msgs: map[int64]*tojMsg{}}
}

func (v *tojView) refresh(ctx context.Context) error {
	for {
		page, err := v.client.Difference(ctx, v.pts)
		if err != nil {
			return err
		}
		for _, u := range page.Updates {
			m := u.Message
			if m == nil || m.DialogID != v.dialog {
				continue
			}
			existing := v.msgs[m.MsgID]
			next := &tojMsg{Message: *m}
			if existing != nil {
				next.FirstServerTS = existing.FirstServerTS
			} else if ts, err := time.Parse(time.RFC3339Nano, m.ServerTS); err == nil {
				next.FirstServerTS = ts
			}
			v.msgs[m.MsgID] = next
		}
		v.pts = page.State.PTS
		if page.Kind != "difference_slice" {
			return nil
		}
	}
}

var tokenPattern = regexp.MustCompile(`tk[a-z0-9]+`)

type direction struct {
	Sources           int       `json:"sources"`
	LiveSources       int       `json:"liveSources"`
	Lost              int       `json:"lost"`
	Duplicated        int       `json:"duplicated"`
	Echoed            int       `json:"echoed"`
	TextMismatches    int       `json:"textMismatches"`
	Edited            int       `json:"edited"`
	EditConverged     int       `json:"editConverged"`
	DeletedWithMirror int       `json:"deletedWithMirror"`
	DeleteConverged   int       `json:"deleteConverged"`
	OutOfOrderPairs   int       `json:"outOfOrderPairs"`
	PairsCompared     int       `json:"pairsCompared"`
	LatenciesMs       []float64 `json:"latenciesMs"`
}

type mirror struct {
	live  bool
	text  string
	order string // Slack ts, or the Toj msg_id zero-padded so string order is numeric order
	at    time.Time
}

type snapshot struct {
	TojToSlack   direction `json:"tojToSlack"`
	SlackToToj   direction `json:"slackToToj"`
	Unattributed int       `json:"unattributed"`
	converged    bool
}

func pad(n int64) string {
	s := "0000000000" + itoa(n)
	return s[len(s)-10:]
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func unescape(s string) string {
	return strings.NewReplacer("&lt;", "<", "&gt;", ">", "&amp;", "&").Replace(s)
}

// measure applies the pre-registered definitions to the final state of both sides.
func measure(sources []*source, view *tojView, slackMsgs []slackfake.Msg, bridgeAccount, channel, botID string,
	slackNames map[string]string) snapshot {
	byToken := map[string]*source{}
	byTojID := map[int64]*source{}
	bySendID := map[string]*source{}
	for _, s := range sources {
		byToken[s.Token] = s
		if s.Origin == "toj" {
			byTojID[s.TojMsgID] = s
		} else {
			bySendID[bridge.SlackSendID(channel, s.SlackTS)] = s
		}
	}
	mirrors := map[*source][]mirror{}
	var snap snapshot
	echoes := map[string]int{}

	// Bridge-authored Toj messages.
	for _, m := range view.msgs {
		if m.SenderAccountID != bridgeAccount {
			continue
		}
		s := byToken[tokenPattern.FindString(m.Text)]
		if s == nil {
			s = bySendID[m.ClientMsgID]
		}
		if s == nil {
			snap.Unattributed++
			continue
		}
		if s.Origin == "toj" {
			echoes["toj"]++ // a Toj message came back into Toj
			continue
		}
		mirrors[s] = append(mirrors[s], mirror{live: m.State == "visible", text: m.Text, order: pad(m.MsgID), at: m.FirstServerTS})
	}
	// Bridge posts in Slack.
	for _, m := range slackMsgs {
		if m.BotID != botID {
			continue
		}
		s := byToken[tokenPattern.FindString(m.Text)]
		if s == nil && m.Metadata != nil && m.Metadata.EventType == slack.MetadataEventType {
			s = byTojID[m.Metadata.EventPayload.TojMsgID]
		}
		if s == nil {
			snap.Unattributed++
			continue
		}
		if s.Origin == "slack" {
			echoes["slack"]++
			continue
		}
		mirrors[s] = append(mirrors[s], mirror{live: !m.Deleted, text: m.Text, order: m.TS, at: m.CreatedAt})
	}
	snap.TojToSlack.Echoed = echoes["slack"]
	snap.SlackToToj.Echoed = echoes["toj"]

	converged := true
	type ordered struct{ src, dst string }
	pairs := map[string][]ordered{}
	for _, s := range sources {
		d := &snap.TojToSlack
		expected := slackEscape(s.Text)
		srcOrder := pad(s.TojMsgID)
		if s.Origin == "slack" {
			d = &snap.SlackToToj
			expected = slackNames[s.Author] + ": " + unescape(s.Text)
			srcOrder = s.SlackTS
		}
		d.Sources++
		ms := mirrors[s]
		if len(ms) > 1 {
			d.Duplicated++
		}
		if len(ms) == 1 {
			pairs[s.Origin] = append(pairs[s.Origin], ordered{src: srcOrder, dst: ms[0].order})
		}
		if len(ms) > 0 {
			first := ms[0].at
			for _, m := range ms[1:] {
				if m.at.Before(first) {
					first = m.at
				}
			}
			if !first.IsZero() {
				d.LatenciesMs = append(d.LatenciesMs, float64(first.Sub(s.CreatedAt).Microseconds())/1000)
			}
		}
		if s.Deleted {
			if len(ms) > 0 {
				d.DeletedWithMirror++
				all := true
				for _, m := range ms {
					all = all && !m.live
				}
				if all {
					d.DeleteConverged++
				} else {
					converged = false
				}
			}
			continue
		}
		d.LiveSources++
		var live *mirror
		for i := range ms {
			if ms[i].live {
				live = &ms[i]
			}
		}
		if live == nil {
			d.Lost++
			converged = false
			continue
		}
		ok := live.text == expected
		if !ok {
			d.TextMismatches++
			converged = false
		}
		if s.Edits > 0 {
			d.Edited++
			if ok {
				d.EditConverged++
			}
		}
	}
	for origin, list := range pairs {
		d := &snap.TojToSlack
		if origin == "slack" {
			d = &snap.SlackToToj
		}
		sort.Slice(list, func(i, j int) bool { return compareOrder(list[i].src, list[j].src) < 0 })
		for i := range list {
			for j := i + 1; j < len(list); j++ {
				d.PairsCompared++
				if compareOrder(list[i].dst, list[j].dst) > 0 {
					d.OutOfOrderPairs++
				}
			}
		}
	}
	snap.converged = converged
	return snap
}

// compareOrder compares Slack ts strings and padded Toj ids alike.
func compareOrder(a, b string) int {
	if strings.Contains(a, ".") || strings.Contains(b, ".") {
		return slack.CompareTS(a, b)
	}
	return strings.Compare(a, b)
}
