package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

func comma(n int) string {
	s := fmt.Sprint(n)
	if len(s) <= 3 {
		return s
	}
	var parts []string
	for len(s) > 3 {
		parts = append([]string{s[len(s)-3:]}, parts...)
		s = s[:len(s)-3]
	}
	return strings.Join(append([]string{s}, parts...), ",")
}

func seconds(ms float64) string { return fmt.Sprintf("%.2f", ms/1000) }

// render prints a report's tables as markdown, so results files carry no hand-copied numbers.
func render(path string, w io.Writer) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var r report
	if err := json.Unmarshal(raw, &r); err != nil {
		return err
	}
	e := r.Environment
	dirty := ""
	if e.GitDirty {
		dirty = " (working tree differs from this SHA)"
	}
	fmt.Fprintf(w, "- Label: `%s`\n- Git SHA: `%s`%s\n- Date: %s\n- Machine: %s\n- %s; Bun %s; %s; Toxiproxy %s\n",
		e.Label, e.GitSHA, dirty, e.Date, e.Machine, e.Go, e.Bun, e.Postgres, e.Toxiproxy)
	fmt.Fprintf(w, "- Command (from `integrations/slack-bridge`): `%s`\n", e.Command)
	if e.Options.Controls != "" {
		fmt.Fprintf(w, "- Negative control: `%s`\n", e.Options.Controls)
	}
	fmt.Fprintf(w, "- Slack: simulated (the fake in `internal/slackfake`)\n\n")

	fmt.Fprintln(w, "| Scenario | Runs | Source messages | Lost | Duplicated | Echoed | Text mismatches | Unconverged runs | Kills (fallback) | Kills survived |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|---|---|---|")
	for _, s := range r.Summary {
		fmt.Fprintf(w, "| %s | %d | %s | %d | %d | %d | %d | %d | %d (%d) | %d |\n", s.Scenario, s.Runs, comma(s.Sources),
			s.Lost, s.Duplicated, s.Echoed, s.TextMismatches, s.Unconverged, s.Kills, s.KillFallbacks, s.KillsSurvived)
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, "| Scenario | Edits converged | Deletes converged | Out-of-order pairs, Toj to Slack | Out-of-order pairs, Slack to Toj |")
	fmt.Fprintln(w, "|---|---|---|---|---|")
	for _, s := range r.Summary {
		fmt.Fprintf(w, "| %s | %d of %d | %d of %d | %s of %s | %s of %s |\n", s.Scenario,
			s.EditConvergence[0], s.EditConvergence[1], s.DeleteConvergence[0], s.DeleteConvergence[1],
			comma(s.OutOfOrderTojToSlack[0]), comma(s.OutOfOrderTojToSlack[1]),
			comma(s.OutOfOrderSlackToToj[0]), comma(s.OutOfOrderSlackToToj[1]))
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, "| Scenario | Retry deliveries | Duplicate deliveries | Late acks injected | Undeliverable (never answered by the bridge) | 429s injected | Calls during Retry-After | Replies dropped after commit |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|---|")
	for _, s := range r.Summary {
		fmt.Fprintf(w, "| %s | %s | %d | %d | %d (%d) | %d | %d | %d |\n", s.Scenario, comma(s.RetryDeliveries),
			s.DuplicatesInjected, s.SlowAcksInjected, s.Undeliverable, s.UndeliverableUnseen, s.RateLimited, s.RateLimitViolations, s.RepliesDropped)
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, "| Scenario | Acks | Ack p50 (ms) | Ack p99 (ms) | Ack max (ms) | Acks at or over 3 s | Toj to Slack p50 / p99 (s) | Slack to Toj p50 / p99 (s) |")
	fmt.Fprintln(w, "|---|---|---|---|---|---|---|---|")
	for _, s := range r.Summary {
		fmt.Fprintf(w, "| %s | %s | %.1f | %.1f | %.1f | %d | %s / %s | %s / %s |\n", s.Scenario, comma(s.Acks),
			s.AckP50Ms, s.AckP99Ms, s.AckMaxMs, s.AcksOver3s,
			seconds(s.TojToSlackP50Ms), seconds(s.TojToSlackP99Ms), seconds(s.SlackToTojP50Ms), seconds(s.SlackToTojP99Ms))
	}
	return nil
}
