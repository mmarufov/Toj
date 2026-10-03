// Command chaos measures the Slack bridge under faults. It runs the real Toj server, Toxiproxy
// between the bridge and Toj, the fake Slack, and the bridge as a separate process that it kills
// with SIGKILL. Definitions: docs/results/slack-bridge-preregistration.md.
//
//	DATABASE_URL=postgres://localhost:5432/toj_slackbridge_chaos go run ./chaos --runs 2 --out out.json
//	go run ./chaos render out.json      # markdown tables
//
// It refuses a database that is not on this machine, a hosted NODE_ENV, and Toxiproxy on 8474.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"math/rand/v2"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/slackfake"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/store"
	"github.com/mmarufov/Toj/integrations/slack-bridge/internal/toj"
)

type scenario struct {
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Toxics      []toxic `json:"toxics"`
	Pulse       *pulse  `json:"pulse,omitempty"`
}

type pulse struct {
	Toxics  []toxic `json:"toxics"`
	EveryMs int     `json:"everyMs"`
	OnMs    int     `json:"onMs"`
}

// The scenarios of the sync chaos harness (server/chaos/run.ts), here between the bridge and Toj.
var scenarios = []scenario{
	{Name: "clean", Description: "no toxics"},
	{Name: "3g", Description: "300 ms +/- 200 ms downstream latency, 40 KB/s each way", Toxics: []toxic{
		{Name: "latency", Type: "latency", Stream: "downstream", Attributes: map[string]int{"latency": 300, "jitter": 200}},
		{Name: "bw_down", Type: "bandwidth", Stream: "downstream", Attributes: map[string]int{"rate": 40}},
		{Name: "bw_up", Type: "bandwidth", Stream: "upstream", Attributes: map[string]int{"rate": 40}},
	}},
	{Name: "resets", Description: "reset_peer both ways for 200 ms out of every 1 s", Pulse: &pulse{EveryMs: 1000, OnMs: 200, Toxics: []toxic{
		{Name: "reset_up", Type: "reset_peer", Stream: "upstream", Attributes: map[string]int{"timeout": 0}},
		{Name: "reset_down", Type: "reset_peer", Stream: "downstream", Attributes: map[string]int{"timeout": 0}},
	}}},
	{Name: "reply_dropped", Description: "20% of connections: request reaches Toj, reply dropped, link closed after 1 s", Toxics: []toxic{
		{Name: "drop_reply", Type: "timeout", Stream: "downstream", Toxicity: 0.2, Attributes: map[string]int{"timeout": 1000}},
	}},
	{Name: "reply_cut", Description: "20% of connections: closed after 300 downstream bytes", Toxics: []toxic{
		{Name: "cut_reply", Type: "limit_data", Stream: "downstream", Toxicity: 0.2, Attributes: map[string]int{"bytes": 300}},
	}},
}

// mild is the CI smoke's version of each scenario, as in the sync chaos harness.
var mild = map[string]scenario{
	"3g": {Toxics: []toxic{{Name: "latency", Type: "latency", Stream: "downstream", Attributes: map[string]int{"latency": 50, "jitter": 25}}}},
	"resets": {Pulse: &pulse{EveryMs: 1000, OnMs: 50, Toxics: []toxic{
		{Name: "reset_up", Type: "reset_peer", Stream: "upstream", Attributes: map[string]int{"timeout": 0}}}}},
	"reply_dropped": {Toxics: []toxic{{Name: "drop_reply", Type: "timeout", Stream: "downstream", Toxicity: 0.05, Attributes: map[string]int{"timeout": 500}}}},
	"reply_cut":     {Toxics: []toxic{{Name: "cut_reply", Type: "limit_data", Stream: "downstream", Toxicity: 0.05, Attributes: map[string]int{"bytes": 300}}}},
}

var defaultKillPoints = []string{"after_slack_post", "after_toj_send", "after_event_ack", "random"}

type options struct {
	Runs           int      `json:"runs"`
	Messages       int      `json:"messages"`
	Kills          int      `json:"kills"`
	Scenarios      []string `json:"scenarios"`
	Seed           uint64   `json:"seed"`
	Toxiproxy      string   `json:"toxiproxy"`
	SpawnToxiproxy bool     `json:"spawnToxiproxy"`
	ProxyPort      int      `json:"proxyPort"`
	ProxyListen    string   `json:"proxyListenHost"`
	UpstreamHost   string   `json:"upstreamHost"`
	ServerDir      string   `json:"serverDir"`
	Converge       string   `json:"convergeTimeout"`
	Mild           bool     `json:"mild"`
	Label          string   `json:"label"`
	Controls       string   `json:"negativeControls"`
	ControlSet     string   `json:"controlSet"`
	P429           float64  `json:"p429"`
	KillPoints     []string `json:"killPoints"`
	Pacer          string   `json:"pacer"`
	GapMs          int      `json:"gapMs"`
	LogDir         string   `json:"logDir"`
	out            string
}

func parseOptions(args []string) options {
	fs := flag.NewFlagSet("chaos", flag.ExitOnError)
	var o options
	var scenarioList, killList string
	fs.IntVar(&o.Runs, "runs", 2, "runs per scenario")
	fs.IntVar(&o.Messages, "messages", 200, "source messages per run, half per side")
	fs.IntVar(&o.Kills, "kills", 3, "SIGKILLs of the bridge per run")
	fs.StringVar(&scenarioList, "scenarios", "clean,3g,resets,reply_dropped,reply_cut", "comma-separated")
	fs.Uint64Var(&o.Seed, "seed", 1, "base seed; run i uses seed+i")
	fs.StringVar(&o.Toxiproxy, "toxiproxy", "http://127.0.0.1:18474", "Toxiproxy API (never 8474)")
	fs.BoolVar(&o.SpawnToxiproxy, "spawn-toxiproxy", true, "start toxiproxy-server if it is not running")
	fs.IntVar(&o.ProxyPort, "proxy-port", 26300, "port the bridge reaches Toj on, through Toxiproxy")
	fs.StringVar(&o.ProxyListen, "proxy-listen-host", "127.0.0.1", "host Toxiproxy listens on (0.0.0.0 when it runs in a container)")
	fs.StringVar(&o.UpstreamHost, "upstream-host", "127.0.0.1", "host Toxiproxy reaches Toj on (host.docker.internal from a container)")
	fs.StringVar(&o.ServerDir, "server-dir", "../../server", "Toj server directory")
	fs.StringVar(&o.Converge, "converge-timeout", "120s", "per-run convergence timeout")
	fs.BoolVar(&o.Mild, "mild", false, "CI smoke toxics")
	fs.StringVar(&o.Label, "label", "", "free-text label stored in the results")
	fs.StringVar(&o.Controls, "negative-control", "", "TOJ_BRIDGE_NEGATIVE_CONTROL for the bridge")
	fs.Float64Var(&o.P429, "p-429", 0.03, "probability the fake answers a channel call with 429")
	fs.StringVar(&o.ControlSet, "control-set", "", "run each item once on the first scenario instead of the sweep: "+
		"controls[@kill-point] separated by ';', e.g. 'loop_guard;cursor_tx@after_cursor_commit'")
	fs.StringVar(&killList, "kill-points", strings.Join(defaultKillPoints, ","), "kill k uses point k mod n")
	fs.StringVar(&o.Pacer, "pacer", "20ms", "SLACK_MIN_INTERVAL for the bridge")
	fs.IntVar(&o.GapMs, "gap-ms", 50, "pause between source messages")
	fs.StringVar(&o.LogDir, "log-dir", "", "bridge and server logs (default: a new temp directory)")
	fs.StringVar(&o.out, "out", "", "write the JSON report here")
	fs.Parse(args)
	o.Scenarios = strings.Split(scenarioList, ",")
	o.KillPoints = strings.Split(killList, ",")
	return o
}

func requireLocal(o options) (string, error) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return "", errors.New("DATABASE_URL is required and must name a disposable local database")
	}
	u, err := url.Parse(dbURL)
	if err != nil {
		return "", err
	}
	switch u.Hostname() {
	case "localhost", "127.0.0.1", "::1":
	default:
		return "", fmt.Errorf("refusing non-local database host %q", u.Hostname())
	}
	if env := os.Getenv("NODE_ENV"); env == "production" || env == "staging" {
		return "", errors.New("refusing to run with a hosted NODE_ENV")
	}
	t, err := url.Parse(o.Toxiproxy)
	if err != nil {
		return "", err
	}
	if t.Port() == "8474" {
		return "", errors.New("refusing Toxiproxy on 8474: other sessions use that port; use 18474")
	}
	return dbURL, nil
}

func main() {
	if len(os.Args) > 2 && os.Args[1] == "render" {
		if err := render(os.Args[2], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	o := parseOptions(os.Args[1:])
	report, err := sweep(o)
	if report != nil && o.out != "" {
		raw, _ := json.MarshalIndent(report, "", "  ")
		if werr := os.WriteFile(o.out, append(raw, '\n'), 0o644); werr != nil {
			fmt.Fprintln(os.Stderr, werr)
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "chaos:", err)
		os.Exit(1)
	}
	failed := false
	for _, s := range report.Summary {
		if s.Lost+s.Duplicated+s.Echoed+s.Unconverged+s.AcksOver3s > 0 {
			failed = true
		}
	}
	if failed && o.Controls == "" && o.ControlSet == "" {
		os.Exit(1)
	}
}

type environment struct {
	Label     string  `json:"label"`
	Date      string  `json:"date"`
	GitSHA    string  `json:"gitSha"`
	GitDirty  bool    `json:"gitDirty"`
	Machine   string  `json:"machine"`
	Go        string  `json:"go"`
	Bun       string  `json:"bun"`
	Postgres  string  `json:"postgres"`
	Toxiproxy string  `json:"toxiproxy"`
	Command   string  `json:"command"`
	Options   options `json:"options"`
	Simulated string  `json:"simulated"`
}

type report struct {
	Environment environment `json:"environment"`
	Scenarios   []scenario  `json:"scenarios"`
	SlackFaults any         `json:"slackFaults"`
	Summary     []summary   `json:"summary"`
	Runs        []runResult `json:"runs"`
}

func output(name string, args ...string) string {
	out, err := exec.Command(name, args...).Output()
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(out))
}

func machine() string {
	if runtime.GOOS == "darwin" {
		mem := output("sysctl", "-n", "hw.memsize")
		var bytes int64
		fmt.Sscan(mem, &bytes)
		return fmt.Sprintf("%s; %s; %d cores; %d GB", output("sysctl", "-n", "hw.model"),
			output("sysctl", "-n", "machdep.cpu.brand_string"), runtime.NumCPU(), bytes>>30)
	}
	return fmt.Sprintf("%s; %d cores", output("uname", "-sr"), runtime.NumCPU())
}

func slackConfig(seed uint64, p429 float64) slackfake.Config {
	return slackfake.Config{
		SigningSecret: "chaos-signing-secret", BotToken: "xoxb-chaos", BotID: "B0BRIDGE", BotUserID: "U0BRIDGE",
		AppID: "A0BRIDGE", Seed: seed,
		RetrySchedule: []time.Duration{time.Second, 6 * time.Second, 30 * time.Second},
		AckTimeout:    3 * time.Second, Concurrency: 8,
		PDuplicate: 0.05, ReorderJitter: 300 * time.Millisecond, PSlowAck: 0.05,
		PRateLimit: p429, RetryAfter: time.Second, PDropReply: 0.03,
	}
}

func sweep(o options) (*report, error) {
	dbURL, err := requireLocal(o)
	if err != nil {
		return nil, err
	}
	converge, err := time.ParseDuration(o.Converge)
	if err != nil {
		return nil, err
	}
	if o.LogDir == "" {
		o.LogDir, _ = os.MkdirTemp("", "toj-slack-bridge-chaos-")
	}
	os.MkdirAll(o.LogDir, 0o755)
	ctx := context.Background()
	work, _ := os.MkdirTemp("", "toj-slack-bridge-run-")
	defer os.RemoveAll(work)

	binary := filepath.Join(work, "bridge")
	build := exec.Command("go", "build", "-o", binary, "./cmd/bridge")
	build.Stdout, build.Stderr = os.Stderr, os.Stderr
	if err := build.Run(); err != nil {
		return nil, fmt.Errorf("build bridge: %w", err)
	}
	proxy, err := connectToxiproxy(ctx, o.Toxiproxy, o.SpawnToxiproxy)
	if err != nil {
		return nil, err
	}
	defer proxy.close()
	server, err := startToj(ctx, o.ServerDir, dbURL, filepath.Join(o.LogDir, "toj-server.log"))
	if err != nil {
		return nil, fmt.Errorf("start toj: %w", err)
	}
	defer server.stop()
	direct := fmt.Sprintf("http://127.0.0.1:%d", server.port)

	rep := &report{Environment: environment{
		Label: o.Label, Date: time.Now().UTC().Format(time.RFC3339), GitSHA: output("git", "rev-parse", "HEAD"),
		GitDirty: output("git", "status", "--porcelain", "--", ".", "../../server", "../../.github") != "",
		Machine:  machine(), Go: runtime.Version(), Bun: output("bun", "--version"),
		Postgres: strings.SplitN(output("psql", dbURL, "-tAc", "SELECT version()"), ",", 2)[0], Toxiproxy: proxy.version(),
		Command: "go run ./chaos " + strings.Join(os.Args[1:], " "), Options: o,
		Simulated: "Slack is the in-process fake (internal/slackfake); every Slack-side number is simulated Slack",
	}, SlackFaults: slackConfig(o.Seed, o.P429)}

	// Three accounts per sweep: Toj limits OTP requests per network, so runs share them and each run
	// gets a new group. The bridge's session is carried from run to run and rotates as it goes.
	stamp := time.Now().Unix() % 10000
	signIn := func(n int, name string, st toj.SessionStore) (*toj.Client, error) {
		client := toj.NewClient(direct, st)
		phone := fmt.Sprintf("+1650%03d%04d", 200+n, stamp)
		code, err := client.StartLogin(ctx, phone)
		if err != nil {
			return nil, fmt.Errorf("start login %s: %w", name, err)
		}
		return client, client.CompleteLogin(ctx, phone, code, name)
	}
	alice, err := signIn(1, "Alice", &toj.MemorySessions{})
	if err != nil {
		return nil, err
	}
	bob, err := signIn(2, "Bob", &toj.MemorySessions{})
	if err != nil {
		return nil, err
	}
	bridgeSessions := &toj.MemorySessions{}
	bridgeClient, err := signIn(3, "Slack bridge", bridgeSessions)
	if err != nil {
		return nil, err
	}
	session := bridgeClient.Session()

	var picked []scenario
	for _, name := range o.Scenarios {
		found := false
		for _, s := range scenarios {
			if s.Name == name {
				if m, ok := mild[name]; o.Mild && ok {
					s.Toxics, s.Pulse = m.Toxics, m.Pulse
				}
				picked = append(picked, s)
				found = true
			}
		}
		if !found {
			return nil, fmt.Errorf("unknown scenario %q", name)
		}
	}
	rep.Scenarios = picked

	if o.ControlSet != "" {
		// One run per negative control, sharing the sweep's accounts. Each run is reported under
		// the control's name instead of a scenario name.
		var labels []scenario
		for i, item := range strings.Split(o.ControlSet, ";") {
			controls, killPoint, _ := strings.Cut(strings.TrimSpace(item), "@")
			if controls == "none" {
				controls = "" // the same run with every protection on, as the comparison
			}
			run := o
			run.Controls = controls
			if killPoint != "" {
				run.KillPoints = []string{killPoint}
			}
			sc := picked[0]
			res, next, err := runOnce(ctx, run, sc, 10+i, 1, o.Seed+uint64(i), converge, binary, work, proxy, server.port, direct,
				[]human{{"Alice", alice}, {"Bob", bob}}, session)
			if err != nil {
				return rep, fmt.Errorf("control %s: %w", item, err)
			}
			session = next
			res.Scenario = "control:" + strings.TrimSpace(item)
			labels = append(labels, scenario{Name: res.Scenario, Description: sc.Name + " scenario, bridge with " + controls + " off"})
			rep.Runs = append(rep.Runs, res)
			line, _ := json.Marshal(map[string]any{"event": "chaos.control", "control": res.Scenario,
				"lost": res.Lost(), "duplicated": res.Duplicated(), "echoed": res.Echoed(), "converged": res.Converged,
				"violations": res.Slack.RateLimitViolations})
			fmt.Println(string(line))
		}
		rep.Scenarios = labels
		rep.Summary = summarize(rep.Runs, labels)
		return rep, nil
	}

	index := 0
	for si, sc := range picked {
		for r := 1; r <= o.Runs; r++ {
			seed := o.Seed + uint64(index)
			index++
			res, next, err := runOnce(ctx, o, sc, si, r, seed, converge, binary, work, proxy, server.port, direct,
				[]human{{"Alice", alice}, {"Bob", bob}}, session)
			if err != nil {
				rep.Summary = summarize(rep.Runs, picked)
				return rep, fmt.Errorf("%s run %d: %w", sc.Name, r, err)
			}
			session = next
			rep.Runs = append(rep.Runs, res)
			line, _ := json.Marshal(map[string]any{"event": "chaos.run", "scenario": res.Scenario, "run": res.Run,
				"lost": res.Lost(), "duplicated": res.Duplicated(), "echoed": res.Echoed(), "converged": res.Converged,
				"kills": len(res.Kills), "ms": res.DurationMs})
			fmt.Println(string(line))
		}
	}
	rep.Summary = summarize(rep.Runs, picked)
	return rep, nil
}

type killRecord struct {
	Point    string `json:"point"`
	Armed    int    `json:"armedHit"`
	Fallback bool   `json:"fallback"`
	AtMs     int64  `json:"atMs"`
}

type runResult struct {
	Scenario     string       `json:"scenario"`
	Run          int          `json:"run"`
	Seed         uint64       `json:"seed"`
	Converged    bool         `json:"converged"`
	ConvergeMs   int64        `json:"convergeMs"`
	DurationMs   int64        `json:"durationMs"`
	Kills        []killRecord `json:"kills"`
	TojToSlack   direction    `json:"tojToSlack"`
	SlackToToj   direction    `json:"slackToToj"`
	Unattributed int          `json:"unattributed"`
	Slack        slackStats   `json:"slack"`
	Workload     []string     `json:"workloadErrors"`
}

type slackStats struct {
	EventsCreated       int            `json:"eventsCreated"`
	Deliveries          int            `json:"deliveries"`
	RetryDeliveries     int            `json:"retryDeliveries"`
	RetriesByReason     map[string]int `json:"retriesByReason"`
	DuplicatesInjected  int            `json:"duplicatesInjected"`
	SlowAcksInjected    int            `json:"slowAcksInjected"`
	Undeliverable       int            `json:"undeliverable"`
	UndeliverableUnseen int            `json:"undeliverableUnseen"`
	NonOKAcks           int            `json:"nonOkAcks"`
	RateLimited         int            `json:"rateLimited"`
	RateLimitViolations int            `json:"rateLimitViolations"`
	RepliesDropped      int            `json:"repliesDropped"`
	HistoryCalls        int            `json:"historyCalls"`
	AckMs               []float64      `json:"ackMs"`
}

func (r runResult) Lost() int       { return r.TojToSlack.Lost + r.SlackToToj.Lost }
func (r runResult) Duplicated() int { return r.TojToSlack.Duplicated + r.SlackToToj.Duplicated }
func (r runResult) Echoed() int     { return r.TojToSlack.Echoed + r.SlackToToj.Echoed }

func runOnce(ctx context.Context, o options, sc scenario, si, run int, seed uint64, converge time.Duration,
	binary, work string, proxy *toxiproxy, tojPort int, direct string, humans []human, session store.Session,
) (runResult, store.Session, error) {
	started := time.Now()
	res := runResult{Scenario: sc.Name, Run: run, Seed: seed}
	rng := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
	tag := fmt.Sprintf("s%dr%02d", si, run)

	listen := fmt.Sprintf("127.0.0.1:%d", o.ProxyPort)
	if err := proxy.recreate("toj-bridge", fmt.Sprintf("%s:%d", o.ProxyListen, o.ProxyPort), fmt.Sprintf("%s:%d", o.UpstreamHost, tojPort)); err != nil {
		return res, session, err
	}
	for _, x := range sc.Toxics {
		if err := proxy.add("toj-bridge", x); err != nil {
			return res, session, err
		}
	}
	pulseCtx, stopPulse := context.WithCancel(ctx)
	pulseDone := make(chan struct{})
	go func() {
		defer close(pulseDone)
		if sc.Pulse == nil {
			return
		}
		for pulseCtx.Err() == nil {
			for _, x := range sc.Pulse.Toxics {
				proxy.add("toj-bridge", x)
			}
			time.Sleep(time.Duration(sc.Pulse.OnMs) * time.Millisecond)
			for _, x := range sc.Pulse.Toxics {
				proxy.remove("toj-bridge", x.Name)
			}
			time.Sleep(time.Duration(sc.Pulse.EveryMs-sc.Pulse.OnMs) * time.Millisecond)
		}
	}()
	defer func() { stopPulse(); <-pulseDone }()

	// A new group: the two humans and the bridge.
	groupID := uuid.NewString()
	if err := retry(ctx, func() error {
		return humans[0].client.CreateGroup(ctx, groupID, "Bridge "+tag, []string{humans[1].client.Session().AccountID, session.AccountID})
	}); err != nil {
		return res, session, fmt.Errorf("create group: %w", err)
	}
	readerPts, err := humans[0].client.State(ctx)
	if err != nil {
		return res, session, err
	}
	view := newTojView(humans[0].client, groupID, readerPts)

	// Fresh bridge state, carrying the session over.
	dir := filepath.Join(work, tag)
	os.MkdirAll(dir, 0o755)
	st, err := store.Open(filepath.Join(dir, "bridge.db"))
	if err != nil {
		return res, session, err
	}
	session.PendingRotationID = ""
	if err := st.SaveSession(ctx, session); err != nil {
		return res, session, err
	}
	st.Close()

	cfg := slackConfig(seed, o.P429)
	fake := slackfake.New(cfg)
	fake.AddUser("U0ALICE", "alice")
	fake.AddUser("U0BOB", "bob")
	slackURL, err := fake.Start("127.0.0.1:0")
	if err != nil {
		return res, session, err
	}
	defer fake.Close()
	bridgePort, err := freePort()
	if err != nil {
		return res, session, err
	}
	channel := "C0" + strings.ToUpper(tag)
	bcfg := bridgeConfig{binary: binary, dir: dir, tojURL: "http://" + listen, pairs: groupID + "=" + channel,
		listen: fmt.Sprintf("127.0.0.1:%d", bridgePort), slackURL: slackURL, secret: cfg.SigningSecret,
		token: cfg.BotToken, appID: cfg.AppID, pacer: o.Pacer, controls: o.Controls,
		logPath: filepath.Join(o.LogDir, tag+"-bridge.log")}

	arm := func(k int) (string, string, int) {
		if k >= o.Kills {
			return "", "", 0
		}
		point := o.KillPoints[k%len(o.KillPoints)]
		if point == "random" {
			return "", point, 0
		}
		n := 1 + rng.IntN(5)
		return fmt.Sprintf("%s@%d", point, n), point, n
	}
	env, point, hit := arm(0)
	proc, err := startBridge(bcfg, env)
	if err != nil {
		return res, session, err
	}
	fake.SetEventsURL(fmt.Sprintf("http://127.0.0.1:%d/slack/events", bridgePort))

	w := &workload{}
	workDone := make(chan struct{})
	go func() {
		defer close(workDone)
		w.run(ctx, rng, o.Messages, time.Duration(o.GapMs)*time.Millisecond, humans, fake, channel, groupID, tag)
	}()

	killRng := rand.New(rand.NewPCG(seed^0xabcdef, seed))
	for k := 0; k < o.Kills; k++ {
		record := killRecord{Point: point, Armed: hit}
		if point == "random" {
			time.Sleep(500*time.Millisecond + time.Duration(killRng.Int64N(int64(2500*time.Millisecond))))
		} else {
			select {
			case <-proc.killLine:
			case <-proc.exited:
				return res, session, fmt.Errorf("bridge exited on its own; see %s", bcfg.logPath)
			case <-time.After(20 * time.Second):
				record.Fallback = true
			}
		}
		proc.kill()
		record.AtMs = time.Since(started).Milliseconds()
		res.Kills = append(res.Kills, record)
		time.Sleep(200*time.Millisecond + time.Duration(killRng.Int64N(int64(300*time.Millisecond))))
		env, point, hit = arm(k + 1)
		if proc, err = startBridge(bcfg, env); err != nil {
			return res, session, err
		}
	}
	<-workDone
	res.Workload = w.errors

	names := map[string]string{"U0ALICE": "alice", "U0BOB": "bob"}
	deadline := time.Now().Add(converge)
	var stableSince time.Time
	var snap snapshot
	convergeStart := time.Now()
	for {
		if err := view.refresh(ctx); err != nil {
			time.Sleep(200 * time.Millisecond)
			continue
		}
		snap = measure(w.sources, view, fake.Messages(channel), session.AccountID, channel, cfg.BotID, names)
		if snap.converged && fake.PendingDeliveries() == 0 {
			if stableSince.IsZero() {
				stableSince = time.Now()
			} else if time.Since(stableSince) >= 2*time.Second {
				res.Converged = true
				res.ConvergeMs = stableSince.Sub(convergeStart).Milliseconds()
				break
			}
		} else {
			stableSince = time.Time{}
		}
		if time.Now().After(deadline) {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	proc.stop()
	res.TojToSlack, res.SlackToToj, res.Unattributed = snap.TojToSlack, snap.SlackToToj, snap.Unattributed

	fs := fake.Stats()
	res.Slack = slackStats{EventsCreated: fs.EventsCreated, Deliveries: fs.Deliveries, RetryDeliveries: fs.RetryDeliveries,
		RetriesByReason: fs.RetriesByReason, DuplicatesInjected: fs.DuplicatesInjected, SlowAcksInjected: fs.SlowAcksInjected,
		Undeliverable: fs.Undeliverable, UndeliverableUnseen: fs.UndeliverableUnseen, NonOKAcks: fs.NonOKAcks, RateLimited: fs.RateLimited,
		RateLimitViolations: fs.RateLimitViolations, RepliesDropped: fs.RepliesDropped, HistoryCalls: fs.HistoryCalls}
	for _, d := range fs.AckLatencies {
		res.Slack.AckMs = append(res.Slack.AckMs, float64(d.Microseconds())/1000)
	}

	st, err = store.Open(filepath.Join(dir, "bridge.db"))
	if err != nil {
		return res, session, err
	}
	next, err := st.LoadSession(ctx)
	st.Close()
	if err != nil {
		return res, session, err
	}
	res.DurationMs = time.Since(started).Milliseconds()
	return res, next, nil
}

type summary struct {
	Scenario             string         `json:"scenario"`
	Runs                 int            `json:"runs"`
	Sources              int            `json:"sources"`
	TojToSlackSources    int            `json:"tojToSlackSources"`
	SlackToTojSources    int            `json:"slackToTojSources"`
	Lost                 int            `json:"lost"`
	Duplicated           int            `json:"duplicated"`
	Echoed               int            `json:"echoed"`
	Unattributed         int            `json:"unattributed"`
	TextMismatches       int            `json:"textMismatches"`
	Unconverged          int            `json:"unconverged"`
	Kills                int            `json:"kills"`
	KillFallbacks        int            `json:"killFallbacks"`
	KillsSurvived        int            `json:"killsSurvived"`
	OutOfOrderTojToSlack [2]int         `json:"outOfOrderTojToSlack"`
	OutOfOrderSlackToToj [2]int         `json:"outOfOrderSlackToToj"`
	EditConvergence      [2]int         `json:"editConvergence"`
	DeleteConvergence    [2]int         `json:"deleteConvergence"`
	RetryDeliveries      int            `json:"retryDeliveries"`
	DuplicatesInjected   int            `json:"duplicatesInjected"`
	SlowAcksInjected     int            `json:"slowAcksInjected"`
	Undeliverable        int            `json:"undeliverable"`
	UndeliverableUnseen  int            `json:"undeliverableUnseen"`
	RateLimited          int            `json:"rateLimited"`
	RateLimitViolations  int            `json:"rateLimitViolations"`
	RepliesDropped       int            `json:"repliesDropped"`
	AckP50Ms             float64        `json:"ackP50Ms"`
	AckP99Ms             float64        `json:"ackP99Ms"`
	AckMaxMs             float64        `json:"ackMaxMs"`
	Acks                 int            `json:"acks"`
	AcksOver3s           int            `json:"acksOver3s"`
	TojToSlackP50Ms      float64        `json:"tojToSlackP50Ms"`
	TojToSlackP99Ms      float64        `json:"tojToSlackP99Ms"`
	SlackToTojP50Ms      float64        `json:"slackToTojP50Ms"`
	SlackToTojP99Ms      float64        `json:"slackToTojP99Ms"`
	RetriesByReason      map[string]int `json:"retriesByReason"`
	WorkloadErrors       int            `json:"workloadErrors"`
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	rank := int((p/100)*float64(len(sorted)) + 0.999999)
	if rank < 1 {
		rank = 1
	}
	return sorted[rank-1]
}

func summarize(runs []runResult, picked []scenario) []summary {
	var out []summary
	groups := append([]string{}, func() []string {
		var names []string
		for _, s := range picked {
			names = append(names, s.Name)
		}
		return names
	}()...)
	groups = append(groups, "all")
	for _, name := range groups {
		s := summary{Scenario: name, RetriesByReason: map[string]int{}}
		var acks, t2s, s2t []float64
		for _, r := range runs {
			if name != "all" && r.Scenario != name {
				continue
			}
			s.Runs++
			s.TojToSlackSources += r.TojToSlack.Sources
			s.SlackToTojSources += r.SlackToToj.Sources
			s.Lost += r.Lost()
			s.Duplicated += r.Duplicated()
			s.Echoed += r.Echoed()
			s.Unattributed += r.Unattributed
			s.TextMismatches += r.TojToSlack.TextMismatches + r.SlackToToj.TextMismatches
			if !r.Converged {
				s.Unconverged++
			}
			s.Kills += len(r.Kills)
			for _, k := range r.Kills {
				if k.Fallback {
					s.KillFallbacks++
				}
			}
			if r.Converged && r.Lost()+r.Duplicated()+r.Echoed() == 0 {
				s.KillsSurvived += len(r.Kills)
			}
			s.OutOfOrderTojToSlack[0] += r.TojToSlack.OutOfOrderPairs
			s.OutOfOrderTojToSlack[1] += r.TojToSlack.PairsCompared
			s.OutOfOrderSlackToToj[0] += r.SlackToToj.OutOfOrderPairs
			s.OutOfOrderSlackToToj[1] += r.SlackToToj.PairsCompared
			s.EditConvergence[0] += r.TojToSlack.EditConverged + r.SlackToToj.EditConverged
			s.EditConvergence[1] += r.TojToSlack.Edited + r.SlackToToj.Edited
			s.DeleteConvergence[0] += r.TojToSlack.DeleteConverged + r.SlackToToj.DeleteConverged
			s.DeleteConvergence[1] += r.TojToSlack.DeletedWithMirror + r.SlackToToj.DeletedWithMirror
			s.RetryDeliveries += r.Slack.RetryDeliveries
			s.DuplicatesInjected += r.Slack.DuplicatesInjected
			s.SlowAcksInjected += r.Slack.SlowAcksInjected
			s.Undeliverable += r.Slack.Undeliverable
			s.UndeliverableUnseen += r.Slack.UndeliverableUnseen
			s.RateLimited += r.Slack.RateLimited
			s.RateLimitViolations += r.Slack.RateLimitViolations
			s.RepliesDropped += r.Slack.RepliesDropped
			for k, v := range r.Slack.RetriesByReason {
				s.RetriesByReason[k] += v
			}
			s.WorkloadErrors += len(r.Workload)
			acks = append(acks, r.Slack.AckMs...)
			t2s = append(t2s, r.TojToSlack.LatenciesMs...)
			s2t = append(s2t, r.SlackToToj.LatenciesMs...)
		}
		s.Sources = s.TojToSlackSources + s.SlackToTojSources
		s.Acks = len(acks)
		for _, a := range acks {
			if a >= 3000 {
				s.AcksOver3s++
			}
			if a > s.AckMaxMs {
				s.AckMaxMs = a
			}
		}
		s.AckP50Ms, s.AckP99Ms = percentile(acks, 50), percentile(acks, 99)
		s.TojToSlackP50Ms, s.TojToSlackP99Ms = percentile(t2s, 50), percentile(t2s, 99)
		s.SlackToTojP50Ms, s.SlackToTojP99Ms = percentile(s2t, 50), percentile(s2t, 99)
		out = append(out, s)
	}
	return out
}
