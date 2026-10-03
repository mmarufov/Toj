// Package faults holds the switches the measurement needs: negative controls that turn one
// mechanism off, and kill points where the process stops so the chaos driver can kill -9 it at an
// exact place. Both are read from the environment once and do nothing when unset.
package faults

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Controls turns off one protection each. They exist to prove the protection is what keeps the
// measured count at zero; main refuses to start with any of them unless TOJ_BRIDGE_ALLOW_NEGATIVE_CONTROL=1.
type Controls struct {
	DisableLoopGuard   bool // mirror every message, including the bridge's own
	DisableEventDedupe bool // process every Slack delivery, including retries of a seen event_id
	DisableReconcile   bool // repost an attempted intent without checking channel history
	CursorOutsideTx    bool // commit the Toj cursor before, and separately from, the intents
}

const EnvControls = "TOJ_BRIDGE_NEGATIVE_CONTROL"

func ParseControls(value string) (Controls, error) {
	var c Controls
	for _, name := range strings.Split(value, ",") {
		switch strings.TrimSpace(name) {
		case "":
		case "loop_guard":
			c.DisableLoopGuard = true
		case "event_dedupe":
			c.DisableEventDedupe = true
		case "reconcile":
			c.DisableReconcile = true
		case "cursor_tx":
			c.CursorOutsideTx = true
		default:
			return c, fmt.Errorf("unknown negative control %q", name)
		}
	}
	return c, nil
}

func (c Controls) Any() bool {
	return c.DisableLoopGuard || c.DisableEventDedupe || c.DisableReconcile || c.CursorOutsideTx
}

func (c Controls) String() string {
	var names []string
	if c.DisableLoopGuard {
		names = append(names, "loop_guard")
	}
	if c.DisableEventDedupe {
		names = append(names, "event_dedupe")
	}
	if c.DisableReconcile {
		names = append(names, "reconcile")
	}
	if c.CursorOutsideTx {
		names = append(names, "cursor_tx")
	}
	return strings.Join(names, ",")
}

// Kill points. TOJ_BRIDGE_KILLPOINT=name@n stops the process the nth time it reaches name: it
// prints one line the driver waits for, then blocks until it is killed.
const EnvKillPoint = "TOJ_BRIDGE_KILLPOINT"

const (
	// Slack accepted chat.postMessage; its ts is not recorded yet.
	AfterSlackPost = "after_slack_post"
	// Toj committed a send from Slack; the message map row is not written yet.
	AfterTojSend = "after_toj_send"
	// The Toj cursor was committed; the intents for that page are not (only reachable when
	// CursorOutsideTx is on, because otherwise they are one transaction).
	AfterCursorCommit = "after_cursor_commit"
	// A Slack event was stored and acknowledged; the worker has not processed it.
	AfterEventAck = "after_event_ack"
)

var (
	killOnce  sync.Once
	killName  string
	killAfter int
	killMu    sync.Mutex
	killHits  int
)

func loadKillPoint() {
	value := os.Getenv(EnvKillPoint)
	if value == "" {
		return
	}
	name, count, _ := strings.Cut(value, "@")
	n, err := strconv.Atoi(count)
	if err != nil || n < 1 {
		n = 1
	}
	killName, killAfter = name, n
}

// Reach is called at each named place. When armed for this place and count, it never returns.
func Reach(name string) {
	killOnce.Do(loadKillPoint)
	if killName != name {
		return
	}
	killMu.Lock()
	killHits++
	hit := killHits == killAfter
	killMu.Unlock()
	if !hit {
		return
	}
	fmt.Fprintf(os.Stdout, "{\"event\":\"bridge.killpoint\",\"name\":%q}\n", name)
	os.Stdout.Sync()
	for {
		time.Sleep(time.Hour)
	}
}
