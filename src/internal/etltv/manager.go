package etltv

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
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
	// exitSettle is how long an unrequested slave exit waits to see whether the
	// server is going down. When the server quits, the slave usually exits
	// (etlded fails in its own disconnect path) a moment before the supervisor
	// notices the server's exit.
	exitSettle = 1500 * time.Millisecond
	// connectTimeout is how long a new slave gets to start recording, on top
	// of sv_etltv_delay. A slave rejected with an error dialog (bad password)
	// just sits disconnected, so this is what recovers from it.
	connectTimeout = 60 * time.Second
)

// Process is a started slave, as the supervisor reports it.
type Process interface {
	Signal(sig syscall.Signal) error
	Done() <-chan struct{} // closed once the process has exited and been reaped
}

// StartFunc starts argv with stdout and stderr on out and stdin on /dev/null.
// out is closed by the caller after StartFunc returns, so an implementation
// must not keep it.
type StartFunc func(argv []string, out *os.File) (Process, error)

// StatusFunc queries the master server.
type StatusFunc func() (etlproto.Status, error)

// Meta is written beside each finished demo as <demo>.json and sent with the
// upload.
type Meta struct {
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

// Manager keeps the slave attached while armed and players are present, and
// turns each finished recording into a named demo in Config.DemoDir.
type Manager struct {
	cfg      Config
	start    StartFunc
	status   StatusFunc
	logf     func(format string, args ...any)
	now      func() time.Time
	finished func() // called after each demo lands in DemoDir

	wake    chan struct{}
	closing chan struct{} // closed by Shutdown

	mu          sync.Mutex
	closeReason string
	state       State
	source      string
	run         *slaveRun
	emptySince  time.Time
	failures    int
	retryAt     time.Time
	closed      bool
}

// slaveRun is one slave process, from start until it has been reaped.
type slaveRun struct {
	proc Process
	done chan struct{} // closed after the output is drained, the process reaped and its demo finalized

	started    time.Time
	recorded   bool   // it has started at least one recording
	requested  bool   // we asked it to stop, so its exit is not a failure
	termSent   bool   // etlded treats a second SIGTERM as a fault and skips closing the demo
	stopReason string // end reason for a recording cut short by the exit

	expectMap bool // the previous line was evInit, so a "Server: " line names the map
	mapName   string
	rec       *recording
}

type recording struct {
	raw     string // as the slave printed it: tvdemos/demo0000.tv_84
	tag     string
	mapName string
	started time.Time
	stopped bool // "Stopped demo." seen; the next line says why
}

// NewManager loads the persisted state. finished may be nil.
func NewManager(cfg Config, start StartFunc, status StatusFunc, logf func(string, ...any), finished func()) (*Manager, error) {
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
	}, nil
}

// Run attaches and detaches the slave until ctx is done.
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

// tick attaches when armed and the master has clients, and detaches after the
// master has been empty for IdleDetach.
func (m *Manager) tick() {
	m.mu.Lock()
	armed, run, closed, retryAt := m.state.Armed, m.run, m.closed, m.retryAt
	m.mu.Unlock()
	if closed || !armed || (run == nil && m.now().Before(retryAt)) {
		return
	}

	// Waits for the master to come up after boot, too: no answer, no attach.
	st, err := m.status()
	if err != nil {
		return
	}
	// The slave appears on the master under its own name. Bots count, as they
	// do for autorestart.
	players := st.PlayersExcluding(m.cfg.Name)

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed || !m.state.Armed || m.run != run {
		return // changed while we were querying
	}

	if run == nil {
		if players > 0 {
			m.spawnLocked()
		}
		return
	}
	if run.requested || run.termSent {
		return // already on its way out
	}

	if !run.recorded && m.now().Sub(run.started) > m.connectTimeout() {
		m.logf("slave has not started recording after %s", m.connectTimeout())
		run.stopReason = reasonDisconnect
		go m.terminate(run) // not requested: its exit schedules a retry
		return
	}

	if m.cfg.IdleDetach <= 0 || players > 0 {
		m.emptySince = time.Time{}
		return
	}
	if m.emptySince.IsZero() {
		m.emptySince = m.now()
		return
	}
	if m.now().Sub(m.emptySince) >= m.cfg.IdleDetach {
		m.logf("server empty for %s, detaching", m.cfg.IdleDetach)
		go m.stopRun(run, reasonIdle)
	}
}

func (m *Manager) spawnLocked() {
	r, w, err := os.Pipe()
	if err != nil {
		m.failLocked(fmt.Errorf("create pipe: %w", err))
		return
	}
	proc, err := m.start(slaveArgs(m.cfg), w)
	w.Close()
	if err != nil {
		r.Close()
		m.failLocked(fmt.Errorf("start slave: %w", err))
		return
	}

	run := &slaveRun{proc: proc, done: make(chan struct{}), started: m.now()}
	m.run = run
	m.emptySince = time.Time{}
	m.logf("attaching to 127.0.0.1:%s as %s", m.cfg.MasterPort, m.cfg.Name)
	go m.follow(run, r)
}

// failLocked schedules the next attach attempt: 5s, 10s, 30s, then every 60s.
func (m *Manager) failLocked(err error) {
	if err != nil {
		m.logf("%v", err)
	}
	backoff := []time.Duration{5 * time.Second, 10 * time.Second, 30 * time.Second, 60 * time.Second}
	d := backoff[len(backoff)-1]
	if m.failures < len(backoff) {
		d = backoff[m.failures]
	}
	m.failures++
	m.retryAt = m.now().Add(d)
	m.logf("retrying in %s", d)
}

// follow relays the slave's output to the container log and reacts to it.
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

	var finish *recording
	var reason string
	idle := false

	m.mu.Lock()
	switch ev.kind {
	case evInit:
		// A new map is loading: a recording that just stopped ended with the map.
		run.expectMap = true
		finish, reason = run.takeStopped(), reasonMapChange
	case evMap:
		if run.expectMap {
			run.mapName = ev.value
			run.expectMap = false
		}
	case evRecording:
		// Normally finalized by evInit already; never lose a file regardless.
		finish, reason = run.takeStopped(), reasonMapChange
		run.rec = &recording{raw: ev.value, tag: m.state.Tag, mapName: run.mapName, started: m.now()}
		run.recorded = true
		m.failures = 0
	case evStopped:
		if run.rec != nil {
			run.rec.stopped = true
		}
	case evShutdown:
		if run.requested || run.termSent {
			reason = run.stopReason // the shutdown our own SIGTERM caused
		} else {
			// The master dropped us. ETL has no reconnect, so the slave
			// would idle forever: end it and let the loop attach a new one.
			reason = shutdownReason(ev.value)
			run.stopReason = reason
			idle = true
		}
		finish = run.takeStopped()
	}
	m.mu.Unlock()

	if idle {
		m.logf("disconnected from the server (%s)", ev.value)
	}
	if finish != nil {
		m.finalize(finish, reason)
	}
	if idle {
		go m.terminate(run)
	}
}

func (m *Manager) connectTimeout() time.Duration {
	var delay int
	fmt.Sscanf(m.cfg.Delay, "%d", &delay)
	return connectTimeout + time.Duration(delay)*time.Second
}

// takeStopped returns the recording if "Stopped demo." has been seen for it.
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
	if !run.requested && m.closed {
		run.stopReason = m.closeReason // the server went down, not just us
	}
	// Whatever is still open was cut short, or the slave was killed mid-write.
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
		m.failLocked(fmt.Errorf("slave exited"))
	}
	m.mu.Unlock()

	if finish != nil {
		m.finalize(finish, reason)
	}
}

// stopRun asks the slave to quit, which closes its demo cleanly, and waits
// until it has exited and the demo is finalized.
func (m *Manager) stopRun(run *slaveRun, reason string) {
	m.mu.Lock()
	if !run.requested {
		run.requested = true
		if run.stopReason == "" {
			run.stopReason = reason
		}
	}
	m.mu.Unlock()

	m.terminate(run)
}

// terminate sends the slave its one SIGTERM and waits for it to exit,
// escalating to SIGKILL. etlded's SIGTERM handler runs the whole shutdown
// inside the signal handler and can deadlock there (seen after a kick), so
// SIGTERM alone is not enough.
func (m *Manager) terminate(run *slaveRun) {
	m.mu.Lock()
	first := !run.termSent
	run.termSent = true
	m.mu.Unlock()
	if first {
		run.proc.Signal(syscall.SIGTERM)
	}

	select {
	case <-run.done:
		return
	case <-time.After(stopGrace):
	}
	m.logf("slave did not exit after SIGTERM, killing it")
	run.proc.Signal(syscall.SIGKILL)
	select {
	case <-run.done:
	case <-time.After(killGrace):
	}
}

// Shutdown stops the slave for good. The supervisor calls it before the
// container exits, with reason "quit" when the server exited and "shutdown"
// when the container is being stopped.
func (m *Manager) Shutdown(reason string) {
	m.mu.Lock()
	if !m.closed {
		m.closed = true
		m.closeReason = reason
		close(m.closing)
	}
	run := m.run
	m.mu.Unlock()
	if run != nil {
		m.stopRun(run, reason)
	}
}

// rawPath finds a demo the slave wrote. Its game dir comes from the master's
// fs_game, which is "legacy" unless a mod is set.
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

// finalize moves a closed recording into DemoDir under its final name, with
// its metadata beside it. The metadata goes first, so the demo is complete
// the moment it shows up for the uploader.
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
	meta := Meta{
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
	m.logf("saved %s (%s)", meta.Filename, reason)
	m.finished()
}

// sweepLeftovers finalizes demos left behind when the container died without
// a clean shutdown (OOM kill, host crash), so they are not silently orphaned.
func (m *Manager) sweepLeftovers() {
	matches, _ := filepath.Glob(filepath.Join(m.cfg.homePath(), "*", "tvdemos", "*"))
	for _, p := range matches {
		info, err := os.Stat(p)
		if err != nil || info.IsDir() {
			continue
		}
		m.finalizeFile(p, &recording{started: info.ModTime()}, reasonInterrupted)
	}
}

// Handle serves a control request.
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
	if tag != "" && Sanitize(tag) != tag {
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
	run := m.run
	m.mu.Unlock()

	// Never block the caller: the Lua hook runs inside a server frame.
	msg := "ETLTV disarmed (state file)"
	if run != nil {
		go m.stopRun(run, reasonStop)
		msg += ", stopping the recorder and saving the current demo"
	}
	return Response{OK: true, Message: msg}
}

func (m *Manager) cmdReset() Response {
	m.mu.Lock()
	if err := os.Remove(m.cfg.statePath()); err != nil && !os.IsNotExist(err) {
		m.mu.Unlock()
		return Response{Message: fmt.Sprintf("ETLTV not reset: %v", err)}
	}
	m.state, m.source = resolveState(State{}, false, m.cfg.Autostart)
	run := m.run
	armed := m.state.Armed
	m.mu.Unlock()

	if !armed && run != nil {
		go m.stopRun(run, reasonStop)
	}
	m.poke()
	info := m.Status()
	return Response{OK: true, Message: "state file removed; " + describe(info), Status: &info}
}

// Status reports the recorder's current state.
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
