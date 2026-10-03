// Command bridge mirrors Toj group dialogs into Slack channels and back.
//
//	bridge login --phone +992XXXXXXXXX     sign the bridge's Toj account in once
//	bridge                                 run (configuration from the environment)
//
// Environment:
//
//	TOJ_BASE_URL          Toj API base, e.g. http://127.0.0.1:8788
//	BRIDGE_DB             SQLite path (default slack-bridge.db)
//	BRIDGE_PAIRS          tojDialogId=slackChannelId[,more]
//	BRIDGE_LISTEN         address for the Slack Events endpoint (default 127.0.0.1:8790)
//	SLACK_SIGNING_SECRET  from the Slack app's Basic Information page
//	SLACK_BOT_TOKEN       xoxb- token from OAuth & Permissions
//	SLACK_APP_ID          the app id, used by the loop guard (optional, bot id is always used)
//	SLACK_API_URL         default https://slack.com/api
//	SLACK_MIN_INTERVAL    spacing of calls per channel (default 1s)
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/bridge"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/faults"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slack"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stderr, nil))
	var err error
	if len(os.Args) > 1 && os.Args[1] == "login" {
		err = login(os.Args[2:])
	} else {
		err = run(log)
	}
	if err != nil {
		log.Error("bridge stopped", "err", err)
		os.Exit(1)
	}
}

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func login(args []string) error {
	fs := flag.NewFlagSet("login", flag.ExitOnError)
	phone := fs.String("phone", "", "the bridge account's phone number")
	name := fs.String("name", "Slack bridge", "display name shown to group members")
	fs.Parse(args)
	if *phone == "" {
		return errors.New("--phone is required")
	}
	st, err := store.Open(env("BRIDGE_DB", "slack-bridge.db"))
	if err != nil {
		return err
	}
	defer st.Close()
	ctx := context.Background()
	client := toj.NewClient(env("TOJ_BASE_URL", "http://127.0.0.1:8788"), st)
	code, err := client.StartLogin(ctx, *phone)
	if err != nil {
		return err
	}
	if code == "" {
		fmt.Fprint(os.Stderr, "verification code: ")
		line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		code = strings.TrimSpace(line)
	}
	if err := client.CompleteLogin(ctx, *phone, code, *name); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "signed in as account %s\n", client.Session().AccountID)
	return nil
}

func parsePairs(value string) ([]bridge.Pair, error) {
	var pairs []bridge.Pair
	for _, item := range strings.Split(value, ",") {
		if strings.TrimSpace(item) == "" {
			continue
		}
		dialog, channel, ok := strings.Cut(strings.TrimSpace(item), "=")
		if !ok || dialog == "" || channel == "" {
			return nil, fmt.Errorf("BRIDGE_PAIRS entry %q is not dialog=channel", item)
		}
		pairs = append(pairs, bridge.Pair{TojDialog: dialog, SlackChannel: channel})
	}
	if len(pairs) == 0 {
		return nil, errors.New("BRIDGE_PAIRS is empty: bridging is opt-in per group")
	}
	return pairs, nil
}

func run(log *slog.Logger) error {
	controls, err := faults.ParseControls(os.Getenv(faults.EnvControls))
	if err != nil {
		return err
	}
	if controls.Any() && os.Getenv("TOJ_BRIDGE_ALLOW_NEGATIVE_CONTROL") != "1" {
		return errors.New("negative controls are for measurement only; set TOJ_BRIDGE_ALLOW_NEGATIVE_CONTROL=1")
	}
	pairs, err := parsePairs(os.Getenv("BRIDGE_PAIRS"))
	if err != nil {
		return err
	}
	secret, token := os.Getenv("SLACK_SIGNING_SECRET"), os.Getenv("SLACK_BOT_TOKEN")
	if secret == "" || token == "" {
		return errors.New("SLACK_SIGNING_SECRET and SLACK_BOT_TOKEN are required")
	}
	interval, err := time.ParseDuration(env("SLACK_MIN_INTERVAL", "1s"))
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(env("BRIDGE_DB", "slack-bridge.db"))
	if err != nil {
		return err
	}
	defer st.Close()
	tojClient := toj.NewClient(env("TOJ_BASE_URL", "http://127.0.0.1:8788"), st)
	if err := tojClient.Load(ctx); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return errors.New("no Toj session: run `bridge login` first")
		}
		return fmt.Errorf("load toj session: %w", err)
	}
	slackClient := slack.NewClient(env("SLACK_API_URL", "https://slack.com/api"), token)
	identity, err := slackClient.AuthTest(ctx)
	if err != nil {
		return fmt.Errorf("slack auth.test: %w", err)
	}

	b := &bridge.Bridge{
		Store: st, Toj: tojClient, Slack: slackClient, Pairs: pairs,
		BotID: identity.BotID, AppID: os.Getenv("SLACK_APP_ID"),
		Controls: controls, MinInterval: interval, Log: log,
	}
	if err := b.Prepare(ctx); err != nil {
		return fmt.Errorf("prepare: %w", err)
	}

	mux := http.NewServeMux()
	stats := &slack.HandlerStats{}
	mux.Handle("/slack/events", &slack.EventsHandler{
		Secret: []byte(secret), Store: st, Wake: b.EventsWake, Controls: controls, Log: log, Stats: stats,
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	if os.Getenv("BRIDGE_DEBUG_STATS") == "1" {
		mux.HandleFunc("/debug/stats", func(w http.ResponseWriter, _ *http.Request) {
			json.NewEncoder(w).Encode(map[string]any{"bridge": snapshot(&b.Stats), "events": map[string]int64{
				"accepted": stats.Accepted.Load(), "duplicates": stats.Duplicates.Load(), "rejected": stats.Rejected.Load(),
			}})
		})
	}
	listener, err := net.Listen("tcp", env("BRIDGE_LISTEN", "127.0.0.1:8790"))
	if err != nil {
		return err
	}
	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	go server.Serve(listener)

	syncer := &toj.Syncer{Client: tojClient, Log: log, Apply: b.ApplyPage,
		Cursor: func(ctx context.Context) (int64, error) {
			pts, _, err := st.Cursor(ctx)
			return pts, err
		}}
	fmt.Fprintf(os.Stdout, "{\"event\":\"bridge.ready\",\"listen\":%q,\"controls\":%q}\n", listener.Addr().String(), controls.String())

	err = b.Run(ctx, syncer)
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server.Shutdown(shutdown)
	if errors.Is(err, context.Canceled) {
		return nil
	}
	return err
}

func snapshot(s *bridge.Stats) map[string]int64 {
	return map[string]int64{
		"tojUpdatesSeen": s.TojUpdatesSeen.Load(), "tojEchoesSuppressed": s.TojEchoesSuppressed.Load(),
		"intentsWritten": s.IntentsWritten.Load(), "slackPosts": s.SlackPosts.Load(),
		"slackUpdates": s.SlackUpdates.Load(), "slackDeletes": s.SlackDeletes.Load(),
		"reconciled": s.Reconciled.Load(), "slackRateLimited": s.SlackRateLimited.Load(),
		"slackUnknownOutcomes": s.SlackUnknownOutcomes.Load(), "intentsSkipped": s.IntentsSkipped.Load(),
		"eventsProcessed": s.EventsProcessed.Load(), "slackEchoesByBotID": s.SlackEchoesByBotID.Load(),
		"slackEchoesByTS": s.SlackEchoesByTS.Load(), "slackEchoesByMetadata": s.SlackEchoesByMetadata.Load(),
		"tojSends": s.TojSends.Load(), "tojDuplicateAcks": s.TojDuplicateAcks.Load(),
		"tojEdits": s.TojEdits.Load(), "tojEditConflicts": s.TojEditConflicts.Load(),
		"tojDeletes": s.TojDeletes.Load(), "eventsIgnored": s.EventsIgnored.Load(),
		"staleEditsDropped": s.StaleEditsDropped.Load(), "tombstonesWritten": s.TombstonesWritten.Load(),
		"tojSendRetries": s.TojSendRetries.Load(),
	}
}
