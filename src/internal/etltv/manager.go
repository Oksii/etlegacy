package etltv

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/oksii/etlegacy/src/internal/etlproto"
)

const (
	tickInterval = 5 * time.Second
	stopGrace    = 3 * time.Second // SIGTERM to SIGKILL
	killGrace    = 2 * time.Second
	// On a server quit the slave exits just before the supervisor sees the
	// server go; an unrequested exit waits this long to tell the two apart.
	exitSettle = 1500 * time.Millisecond
	// A rejected slave (bad password) idles forever; this, plus any delay, is
	// how long it gets to start recording.
	connectTimeout = 60 * time.Second
)

type Process interface {
	Signal(sig syscall.Signal) error
	Done() <-chan struct{} // closed once the process has been reaped
}

type StartFunc func(argv []string, out *os.File) (Process, error)

type StatusFunc func() (etlproto.Status, error)

type demoMeta struct {
	Filename   string    `json:"filename"`
	Map        string    `json:"map"`
	Tag        string    `json:"tag,omitempty"`
	StartedAt  time.Time `json:"started_at"`
	EndedAt    time.Time `json:"ended_at"`
	EndReason  string    `json:"end_reason"`
	ServerIP   string    `json:"server_ip,omitempty"`
	ServerPort string    `json:"server_port"`
	Hostname   string    `json:"hostname"`
}

type Manager struct {
	cfg      Config
	start    StartFunc
	status   StatusFunc
	logf     func(format string, args ...any)
	now      func() time.Time
	finished func() // a demo landed in DemoDir

	wake    chan struct{}
	closing chan struct{} // closed by Shutdown

	mu         sync.Mutex
	state      State
	source     string
	run        *slaveRun
	emptySince time.Time
	failures   int
	retryAt    time.Time
	closed     bool
}

type slaveRun struct {
	proc    Process
	done    chan struct{}
	started time.Time

	recorded   bool
	requested  bool
	termSent   bool
	stopReason string

	expectMap bool
	mapName   string
	rec       *recording
}

type recording struct {
	raw     string // tvdemos/demo0000.tv_84
	tag     string
	mapName string
	started time.Time
	stopped bool // "Stopped demo."
}

func NewManager(cfg Config, start StartFunc, status StatusFunc, logf func(string, ...any), finished func()) *Manager {
	file, exists, err := loadState(cfg.statePath())
	if err != nil {
		logf("ignoring unreadable state file %s: %v", cfg.statePath(), err)
		exists = false
	}
	state, source := resolveState(file, exists, cfg.Autostart)
	if finished == nil {
		finished = func() {}
	}
	return &Manager{
		cfg:      cfg,
		start:    start,
		status:   status,
		logf:     logf,
		now:      time.Now,
		finished: finished,
		wake:     make(chan struct{}, 1),
		closing:  make(chan struct{}),
		state:    state,
		source:   source,
	}
}

func (m *Manager) Run(ctx context.Context) {
	m.sweepLeftovers()
	if m.state.Armed {
		m.logf("armed (%s), recording whenever players are on the server", m.source)
	}

	t := time.NewTicker(tickInterval)
	defer t.Stop()
	for {
		m.tick()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-m.wake:
		}
	}
}

func (m *Manager) poke() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

func (m *Manager) tick() {
	m.mu.Lock()
	armed, run, closed, retryAt := m.state.Armed, m.run, m.closed, m.retryAt
	m.mu.Unlock()
	if closed || !armed || (run == nil && m.now().Before(retryAt)) {
		return
	}

	st, err := m.status()
	if err != nil {
		return
	}
	players := st.PlayersExcluding(m.cfg.Name) // bots count, as for autorestart

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || !m.state.Armed || m.run != run || (run != nil && run.termSent) {
		return
	}

	switch {
	case run == nil:
		if players > 0 {
			m.spawnLocked()
		}
	case !run.recorded && m.now().Sub(run.started) > m.connectTimeout():
		m.logf("slave has not started recording after %s", m.connectTimeout())
		run.stopReason = reasonDisconnect
		m.endLocked(run)
	case m.cfg.IdleDetach <= 0 || players > 0:
		m.emptySince = time.Time{}
	case m.emptySince.IsZero():
		m.emptySince = m.now()
	case m.now().Sub(m.emptySince) >= m.cfg.IdleDetach:
		m.logf("server empty for %s, detaching", m.cfg.IdleDetach)
		m.requestStopLocked(run, reasonIdle)
		m.endLocked(run)
	}
}

func (m *Manager) spawnLocked() {
	r, w, err := os.Pipe()
	if err != nil {
		m.retryLocked(fmt.Sprintf("create pipe: %v", err))
		return
	}
	proc, err := m.start(slaveArgs(m.cfg), w)
	w.Close()
	if err != nil {
		r.Close()
		m.retryLocked(fmt.Sprintf("start slave: %v", err))
		return
	}

	run := &slaveRun{proc: proc, done: make(chan struct{}), started: m.now()}
	m.run = run
	m.emptySince = time.Time{}
	m.logf("attaching to 127.0.0.1:%s as %s", m.cfg.MasterPort, m.cfg.Name)
	go m.follow(run, r)
}

func (m *Manager) retryLocked(why string) {
	backoff := []time.Duration{5 * time.Second, 10 * time.Second, 30 * time.Second, 60 * time.Second}
	d := backoff[min(m.failures, len(backoff)-1)]
	m.failures++
	m.retryAt = m.now().Add(d)
	m.logf("%s, retrying in %s", why, d)
}

func (m *Manager) follow(run *slaveRun, r io.ReadCloser) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		fmt.Printf("[etltv] %s\n", line)
		m.handleLine(run, line)
	}
	r.Close()
	<-run.proc.Done()
	m.handleExit(run)
	close(run.done)
}

func (m *Manager) handleLine(run *slaveRun, line string) {
	ev := parseLine(line)
	if ev.kind == evNone {
		return
	}

	var finish, begun *recording
	var reason string

	m.mu.Lock()
	switch ev.kind {
	case evInit:
		// A new map is loading: a just-stopped recording ended with the map.
		run.expectMap = true
		finish, reason = run.takeStopped(), reasonMapChange
	case evMap:
		if run.expectMap {
			run.mapName = ev.value
			run.expectMap = false
		}
	case evRecording:
		finish, reason = run.takeStopped(), reasonMapChange // normally done by evInit already
		run.rec = &recording{raw: ev.value, tag: m.state.Tag, mapName: run.mapName, started: m.now()}
		begun = run.rec
		run.recorded = true
		m.failures = 0
	case evStopped:
		if run.rec != nil {
			run.rec.stopped = true
		}
	case evShutdown:
		if !run.termSent {
			run.stopReason = shutdownReason(ev.value)
			m.logf("disconnected from the server (%s)", ev.value)
			m.endLocked(run)
		}
		finish, reason = run.takeStopped(), run.stopReason
	}
	m.mu.Unlock()

	if finish != nil {
		m.finalize(finish, reason)
	}
	// After the finalize above, which clears the previous demo's entry.
	if begun != nil {
		live := liveRecording{Raw: filepath.Base(begun.raw), Tag: begun.tag, Map: begun.mapName, Started: begun.started}
		if err := saveRecording(m.cfg.recordingPath(), live); err != nil {
			m.logf("save %s: %v", m.cfg.recordingPath(), err)
		}
	}
}

func (m *Manager) connectTimeout() time.Duration {
	delay, _ := strconv.Atoi(m.cfg.Delay)
	return connectTimeout + time.Duration(delay)*time.Second
}

func (r *slaveRun) takeStopped() *recording {
	if r.rec == nil || !r.rec.stopped {
		return nil
	}
	rec := r.rec
	r.rec = nil
	return rec
}

func (m *Manager) handleExit(run *slaveRun) {
	m.mu.Lock()
	unrequested := !run.requested
	m.mu.Unlock()
	if unrequested {
		select {
		case <-m.closing:
		case <-time.After(exitSettle):
		}
	}

	m.mu.Lock()
	finish := run.rec
	run.rec = nil
	reason := run.stopReason
	if reason == "" {
		reason = reasonDisconnect
	}
	if m.run == run {
		m.run = nil
	}
	if !run.requested && m.state.Armed && !m.closed {
		m.retryLocked("slave exited")
	}
	m.mu.Unlock()

	if finish != nil {
		m.finalize(finish, reason)
	}
}

func (m *Manager) requestStopLocked(run *slaveRun, reason string) {
	run.requested = true
	if run.stopReason == "" {
		run.stopReason = reason
	}
}

// endLocked sends the one SIGTERM, which closes the demo cleanly, then SIGKILL
// if needed: etlded's shutdown runs in its signal handler and can deadlock.
func (m *Manager) endLocked(run *slaveRun) {
	if run.termSent {
		return
	}
	run.termSent = true
	run.proc.Signal(syscall.SIGTERM)
	go func() {
		select {
		case <-run.done:
		case <-time.After(stopGrace):
			m.logf("slave did not exit after SIGTERM, killing it")
			run.proc.Signal(syscall.SIGKILL)
		}
	}()
}

func (m *Manager) Shutdown(reason string) {
	m.mu.Lock()
	if !m.closed {
		m.closed = true
		close(m.closing)
	}
	run := m.run
	if run != nil {
		m.requestStopLocked(run, reason)
		m.endLocked(run)
	}
	m.mu.Unlock()

	if run != nil {
		select {
		case <-run.done:
		case <-time.After(stopGrace + killGrace):
		}
	}
}

func (m *Manager) rawPath(raw string) string {
	home := m.cfg.homePath()
	if p := filepath.Join(home, "legacy", raw); fileExists(p) {
		return p
	}
	matches, _ := filepath.Glob(filepath.Join(home, "*", raw))
	if len(matches) > 0 {
		return matches[0]
	}
	return ""
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// The metadata is written first, so a demo is complete once it appears.
func (m *Manager) finalize(rec *recording, reason string) {
	src := m.rawPath(rec.raw)
	if src == "" {
		m.logf("finished demo %s not found, skipping", rec.raw)
		return
	}
	m.finalizeFile(src, rec, reason)
}

func (m *Manager) finalizeFile(src string, rec *recording, reason string) {
	if err := os.MkdirAll(m.cfg.DemoDir, 0755); err != nil {
		m.logf("create %s: %v", m.cfg.DemoDir, err)
		return
	}

	dst := uniquePath(m.cfg.DemoDir, demoName(rec.tag, rec.mapName, filepath.Ext(src), rec.started))
	meta := demoMeta{
		Filename:   filepath.Base(dst),
		Map:        rec.mapName,
		Tag:        rec.tag,
		StartedAt:  rec.started,
		EndedAt:    m.now(),
		EndReason:  reason,
		ServerIP:   m.cfg.ServerIP,
		ServerPort: m.cfg.MasterPort,
		Hostname:   m.cfg.Hostname,
	}
	data, _ := json.MarshalIndent(meta, "", "  ")
	if err := writeFileAtomic(dst+".json", data); err != nil {
		m.logf("write metadata for %s: %v", meta.Filename, err)
		return
	}
	if err := moveFile(src, dst); err != nil {
		m.logf("move %s to %s: %v", src, dst, err)
		os.Remove(dst + ".json")
		return
	}
	// Only if it is still this demo's: a new slave may already have started the next.
	if live := loadRecording(m.cfg.recordingPath()); live != nil && live.Started.Equal(rec.started) {
		os.Remove(m.cfg.recordingPath())
	}
	m.logf("saved %s (%s)", meta.Filename, reason)
	m.finished()
}

// sweepLeftovers finalizes demos left by an unclean exit (OOM kill, crash).
func (m *Manager) sweepLeftovers() {
	live := loadRecording(m.cfg.recordingPath())
	matches, _ := filepath.Glob(filepath.Join(m.cfg.homePath(), "*", "tvdemos", "*"))
	for _, p := range matches {
		info, err := os.Stat(p)
		if err != nil || info.IsDir() {
			continue
		}
		rec := &recording{started: info.ModTime()}
		if live != nil && live.Raw == filepath.Base(p) {
			rec = &recording{tag: live.Tag, mapName: live.Map, started: live.Started}
			live = nil
		}
		m.finalizeFile(p, rec, reasonInterrupted)
	}
}

func (m *Manager) Handle(req Request) Response {
	switch req.Cmd {
	case "start":
		return m.cmdStart(req.Tag)
	case "stop":
		return m.cmdStop()
	case "reset":
		return m.cmdReset()
	case "status":
		info := m.Status()
		return Response{OK: true, Message: describe(info), Status: &info}
	}
	return Response{Message: fmt.Sprintf("unknown command %q (use start [tag], stop, status or reset)", req.Cmd)}
}

func (m *Manager) preflight() error {
	if m.cfg.TVPassword == "" {
		return fmt.Errorf("SVETLTVPASSWORD is empty, and the server rejects TV slaves without a password")
	}
	if m.cfg.MaxSlaves == "0" {
		return fmt.Errorf("SVETLTVMAXSLAVES is 0, so the server has no slot for a TV slave")
	}
	if matches, _ := filepath.Glob(filepath.Join(m.cfg.BasePath, "legacy", "tvgame.mp.*.so")); len(matches) == 0 {
		return fmt.Errorf("no tvgame module in %s/legacy, this build cannot run a TV slave", m.cfg.BasePath)
	}
	return nil
}

func (m *Manager) cmdStart(tag string) Response {
	if tag != "" && sanitize(tag) != tag {
		return Response{Message: "tag may only contain A-Z a-z 0-9 . _ - (max 64)"}
	}
	if err := m.preflight(); err != nil {
		return Response{Message: "ETLTV not started: " + err.Error()}
	}

	m.mu.Lock()
	state := State{Armed: true, Tag: tag}
	if err := saveState(m.cfg.statePath(), state); err != nil {
		m.mu.Unlock()
		return Response{Message: fmt.Sprintf("ETLTV not started: save state: %v", err)}
	}
	m.state, m.source = state, sourceStateFile
	m.failures, m.retryAt = 0, time.Time{}
	m.mu.Unlock()

	m.poke()
	info := m.Status()
	return Response{OK: true, Message: describe(info), Status: &info}
}

func (m *Manager) cmdStop() Response {
	m.mu.Lock()
	if err := saveState(m.cfg.statePath(), State{}); err != nil {
		m.mu.Unlock()
		return Response{Message: fmt.Sprintf("ETLTV not stopped: save state: %v", err)}
	}
	m.state, m.source = State{}, sourceStateFile
	msg := "ETLTV disarmed (state file)"
	if m.run != nil {
		m.requestStopLocked(m.run, reasonStop)
		m.endLocked(m.run)
		msg += ", stopping the recorder and saving the current demo"
	}
	m.mu.Unlock()
	return Response{OK: true, Message: msg}
}

func (m *Manager) cmdReset() Response {
	m.mu.Lock()
	if err := os.Remove(m.cfg.statePath()); err != nil && !os.IsNotExist(err) {
		m.mu.Unlock()
		return Response{Message: fmt.Sprintf("ETLTV not reset: %v", err)}
	}
	m.state, m.source = resolveState(State{}, false, m.cfg.Autostart)
	if !m.state.Armed && m.run != nil {
		m.requestStopLocked(m.run, reasonStop)
		m.endLocked(m.run)
	}
	m.mu.Unlock()

	m.poke()
	info := m.Status()
	return Response{OK: true, Message: "state file removed; " + describe(info), Status: &info}
}

func (m *Manager) Status() StatusInfo {
	m.mu.Lock()
	defer m.mu.Unlock()
	info := StatusInfo{
		Armed:  m.state.Armed,
		Source: m.source,
		Tag:    m.state.Tag,
		Name:   m.cfg.Name,
	}
	if m.run != nil {
		info.Attached = true
		info.Map = m.run.mapName
		if rec := m.run.rec; rec != nil && !rec.stopped {
			info.Recording = filepath.Base(rec.raw)
			info.Since = rec.started
		}
	}
	return info
}

func describe(s StatusInfo) string {
	var b strings.Builder
	if !s.Armed {
		fmt.Fprintf(&b, "ETLTV disarmed (%s)", s.Source)
	} else {
		fmt.Fprintf(&b, "ETLTV armed (%s)", s.Source)
		if s.Tag != "" {
			fmt.Fprintf(&b, ", tag %s", s.Tag)
		}
	}
	switch {
	case s.Recording != "":
		fmt.Fprintf(&b, ", recording %s", s.Recording)
		if s.Map != "" {
			fmt.Fprintf(&b, " on %s", s.Map)
		}
		fmt.Fprintf(&b, " since %s", s.Since.Format("15:04:05"))
	case s.Attached:
		b.WriteString(", slave connecting")
	case s.Armed:
		b.WriteString(", waiting for players")
	}
	return b.String()
}
