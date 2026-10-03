package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func waitHTTP(ctx context.Context, url string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(url)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
	return fmt.Errorf("%s not ready after %s", url, timeout)
}

// Toj server

type tojServer struct {
	cmd  *exec.Cmd
	port int
	log  *os.File
}

func startToj(ctx context.Context, serverDir, databaseURL, logPath string) (*tojServer, error) {
	port, err := freePort()
	if err != nil {
		return nil, err
	}
	logFile, err := os.Create(logPath)
	if err != nil {
		return nil, err
	}
	cmd := exec.Command("bun", "run", "src/cloud.ts")
	cmd.Dir = serverDir
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("PORT=%d", port),
		"DATABASE_URL="+databaseURL,
		"TOJ_AUTH_SESSIONS_V2_ENABLED=1",
		"TOJ_GROUPS_V1_ENABLED=1",
		"TOJ_PRODUCTIVITY_WORKERS_DISABLED=1",
	)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	s := &tojServer{cmd: cmd, port: port, log: logFile}
	if err := waitHTTP(ctx, fmt.Sprintf("http://127.0.0.1:%d/ready", port), 60*time.Second); err != nil {
		s.stop()
		return nil, err
	}
	return s, nil
}

func (s *tojServer) stop() {
	if s.cmd.Process != nil {
		syscall.Kill(-s.cmd.Process.Pid, syscall.SIGTERM)
		done := make(chan struct{})
		go func() { s.cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
		}
	}
	s.log.Close()
}

// Toxiproxy

type toxic struct {
	Name       string         `json:"name"`
	Type       string         `json:"type"`
	Stream     string         `json:"stream"`
	Toxicity   float64        `json:"toxicity"`
	Attributes map[string]int `json:"attributes"`
}

type toxiproxy struct {
	base string
	cmd  *exec.Cmd
}

func (t *toxiproxy) call(method, path string, body any) error {
	var reader io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		reader = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, t.base+path, reader)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && !(method == http.MethodDelete && resp.StatusCode == 404) {
		msg, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("toxiproxy %s %s: %d %s", method, path, resp.StatusCode, msg)
	}
	return nil
}

func (t *toxiproxy) version() string {
	resp, err := http.Get(t.base + "/version")
	if err != nil {
		return "unknown"
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var v struct {
		Version string `json:"version"`
	}
	if json.Unmarshal(raw, &v) == nil && v.Version != "" {
		return v.Version
	}
	return strings.TrimSpace(string(raw))
}

// connect uses a running Toxiproxy or starts one on the given address.
func connectToxiproxy(ctx context.Context, base string, spawn bool) (*toxiproxy, error) {
	t := &toxiproxy{base: strings.TrimRight(base, "/")}
	if waitHTTP(ctx, t.base+"/version", time.Second) == nil {
		return t, nil
	}
	if !spawn {
		return nil, fmt.Errorf("toxiproxy not reachable at %s", base)
	}
	host := strings.TrimPrefix(strings.TrimPrefix(t.base, "http://"), "https://")
	h, p, err := net.SplitHostPort(host)
	if err != nil {
		return nil, err
	}
	t.cmd = exec.Command("toxiproxy-server", "-host", h, "-port", p)
	t.cmd.Stdout, t.cmd.Stderr = io.Discard, io.Discard
	if err := t.cmd.Start(); err != nil {
		return nil, fmt.Errorf("start toxiproxy-server: %w", err)
	}
	return t, waitHTTP(ctx, t.base+"/version", 10*time.Second)
}

func (t *toxiproxy) close() {
	if t.cmd != nil && t.cmd.Process != nil {
		t.cmd.Process.Kill()
		t.cmd.Wait()
	}
}

// recreate drops every link, so no connection survives into the next run.
func (t *toxiproxy) recreate(name, listen, upstream string) error {
	if err := t.call(http.MethodDelete, "/proxies/"+name, nil); err != nil {
		return err
	}
	return t.call(http.MethodPost, "/proxies", map[string]any{"name": name, "listen": listen, "upstream": upstream, "enabled": true})
}

func (t *toxiproxy) add(proxy string, x toxic) error {
	if x.Toxicity == 0 {
		x.Toxicity = 1
	}
	return t.call(http.MethodPost, "/proxies/"+proxy+"/toxics", x)
}

func (t *toxiproxy) remove(proxy, name string) error {
	return t.call(http.MethodDelete, "/proxies/"+proxy+"/toxics/"+name, nil)
}

// Bridge process

type bridgeProc struct {
	cmd      *exec.Cmd
	killLine chan string
	ready    chan struct{}
	exited   chan struct{}
}

type bridgeConfig struct {
	binary, dir, tojURL, pairs, listen, slackURL, secret, token, appID, pacer, controls string
	logPath                                                                             string
}

func startBridge(cfg bridgeConfig, killPoint string) (*bridgeProc, error) {
	cmd := exec.Command(cfg.binary)
	cmd.Dir = cfg.dir
	env := append(os.Environ(),
		"TOJ_BASE_URL="+cfg.tojURL,
		"BRIDGE_DB="+filepath.Join(cfg.dir, "bridge.db"),
		"BRIDGE_PAIRS="+cfg.pairs,
		"BRIDGE_LISTEN="+cfg.listen,
		"SLACK_API_URL="+cfg.slackURL,
		"SLACK_SIGNING_SECRET="+cfg.secret,
		"SLACK_BOT_TOKEN="+cfg.token,
		"SLACK_APP_ID="+cfg.appID,
		"SLACK_MIN_INTERVAL="+cfg.pacer,
		"TOJ_BRIDGE_KILLPOINT="+killPoint,
	)
	if cfg.controls != "" {
		env = append(env, "TOJ_BRIDGE_NEGATIVE_CONTROL="+cfg.controls, "TOJ_BRIDGE_ALLOW_NEGATIVE_CONTROL=1")
	}
	cmd.Env = env
	logFile, err := os.OpenFile(cfg.logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	cmd.Stderr = logFile
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &bridgeProc{cmd: cmd, killLine: make(chan string, 4), ready: make(chan struct{}), exited: make(chan struct{})}
	var once sync.Once
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			fmt.Fprintln(logFile, line)
			var ev struct {
				Event string `json:"event"`
				Name  string `json:"name"`
			}
			if json.Unmarshal([]byte(line), &ev) != nil {
				continue
			}
			switch ev.Event {
			case "bridge.ready":
				once.Do(func() { close(p.ready) })
			case "bridge.killpoint":
				p.killLine <- ev.Name
			}
		}
	}()
	go func() {
		cmd.Wait()
		logFile.Close()
		close(p.exited)
	}()
	select {
	case <-p.ready:
		return p, nil
	case <-p.exited:
		return nil, fmt.Errorf("bridge exited before ready; see %s", cfg.logPath)
	case <-time.After(30 * time.Second):
		p.kill()
		return nil, fmt.Errorf("bridge not ready after 30s; see %s", cfg.logPath)
	}
}

func (p *bridgeProc) kill() {
	if p.cmd.Process != nil {
		p.cmd.Process.Signal(syscall.SIGKILL)
	}
	<-p.exited
}

func (p *bridgeProc) stop() {
	if p.cmd.Process != nil {
		p.cmd.Process.Signal(syscall.SIGTERM)
	}
	select {
	case <-p.exited:
	case <-time.After(10 * time.Second):
		p.kill()
	}
}
