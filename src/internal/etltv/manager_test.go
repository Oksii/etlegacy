package etltv

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/oksii/etlegacy/src/internal/etlproto"
)

// fakeSlave prints console lines for the test and records the signals it gets.
type fakeSlave struct {
	out  *os.File
	done chan struct{}
	sigs chan syscall.Signal
	once sync.Once
}

func (f *fakeSlave) Signal(sig syscall.Signal) error {
	f.sigs <- sig
	return nil
}

func (f *fakeSlave) Done() <-chan struct{} { return f.done }

func (f *fakeSlave) say(lines ...string) {
	for _, l := range lines {
		fmt.Fprintln(f.out, l)
	}
}

func (f *fakeSlave) exit() {
	f.once.Do(func() {
		f.out.Close()
		close(f.done)
	})
}

type harness struct {
	t       *testing.T
	m       *Manager
	cfg     Config
	slaves  chan *fakeSlave
	started []*fakeSlave

	mu      sync.Mutex
	now     time.Time
	players []string
}

func newHarness(t *testing.T, autostart bool) *harness {
	t.Helper()
	base := t.TempDir()
	os.MkdirAll(filepath.Join(base, "legacy"), 0755)
	os.WriteFile(filepath.Join(base, "legacy", "tvgame.mp.x86_64.so"), nil, 0644)

	cfg := Config{
		Etlded:     "/bin/false",
		BasePath:   base,
		StateDir:   filepath.Join(t.TempDir(), "etltv"),
		DemoDir:    filepath.Join(t.TempDir(), "tvdemos"),
		MasterPort: "27960",
		TVPassword: "3tltv",
		MaxSlaves:  "2",
		Name:       "ETLTV",
		Delay:      "0",
		Autostart:  autostart,
		IdleDetach: 2 * time.Minute,
	}
	return newHarnessWith(t, cfg)
}

func newHarnessWith(t *testing.T, cfg Config) *harness {
	t.Helper()
	h := &harness{
		t:      t,
		cfg:    cfg,
		slaves: make(chan *fakeSlave, 4),
		now:    time.Date(2026, 10, 2, 21, 30, 0, 0, time.UTC),
	}

	start := func(argv []string, out *os.File) (Process, error) {
		fd, err := syscall.Dup(int(out.Fd()))
		if err != nil {
			return nil, err
		}
		f := &fakeSlave{
			out:  os.NewFile(uintptr(fd), "slave"),
			done: make(chan struct{}),
			sigs: make(chan syscall.Signal, 8),
		}
		h.mu.Lock()
		h.started = append(h.started, f)
		h.mu.Unlock()
		h.slaves <- f
		return f, nil
	}
	status := func() (etlproto.Status, error) {
		h.mu.Lock()
		defer h.mu.Unlock()
		return etlproto.Status{Players: len(h.players), Names: append([]string(nil), h.players...)}, nil
	}

	m := NewManager(cfg, start, status, t.Logf, nil)
	m.now = func() time.Time {
		h.mu.Lock()
		defer h.mu.Unlock()
		return h.now
	}
	h.m = m
	t.Cleanup(func() {
		// Fakes ignore signals: end them first instead of waiting out the graces.
		h.mu.Lock()
		for _, f := range h.started {
			f.exit()
		}
		h.mu.Unlock()
		m.Shutdown(reasonShutdown)
	})
	return h
}

func (h *harness) setPlayers(names ...string) {
	h.mu.Lock()
	h.players = names
	h.mu.Unlock()
}

func (h *harness) advance(d time.Duration) {
	h.mu.Lock()
	h.now = h.now.Add(d)
	h.mu.Unlock()
}

func (h *harness) attach() *fakeSlave {
	h.t.Helper()
	h.m.tick()
	select {
	case f := <-h.slaves:
		return f
	case <-time.After(2 * time.Second):
		h.t.Fatal("slave was not started")
		return nil
	}
}

func (h *harness) expectNoAttach() {
	h.t.Helper()
	h.m.tick()
	select {
	case <-h.slaves:
		h.t.Fatal("slave started unexpectedly")
	case <-time.After(100 * time.Millisecond):
	}
}

func (h *harness) writeRaw(name string) {
	h.t.Helper()
	dir := filepath.Join(h.cfg.homePath(), "legacy", "tvdemos")
	os.MkdirAll(dir, 0755)
	if err := os.WriteFile(filepath.Join(dir, name), []byte("demo "+name), 0644); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) recordMap(f *fakeSlave, mapName, raw string) {
	h.writeRaw(raw)
	f.say("----- Server Initialization ----", "Server: "+mapName, "Recording to tvdemos/"+raw+".")
	eventually(h.t, "recording "+raw, func() bool { return h.m.Status().Recording == raw })
}

func (h *harness) finished(name string) demoMeta {
	h.t.Helper()
	path := filepath.Join(h.cfg.DemoDir, name)
	eventually(h.t, "demo "+name, func() bool { return fileExists(path) })
	var meta demoMeta
	data, err := os.ReadFile(path + ".json")
	if err != nil {
		h.t.Fatalf("metadata: %v", err)
	}
	json.Unmarshal(data, &meta)
	return meta
}

func expectSignal(t *testing.T, f *fakeSlave, want syscall.Signal) {
	t.Helper()
	select {
	case got := <-f.sigs:
		if got != want {
			t.Fatalf("signal = %v, want %v", got, want)
		}
	case <-time.After(5 * time.Second): // covers stopGrace before a SIGKILL
		t.Fatalf("no %v sent to the slave", want)
	}
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestRecordsOneDemoPerMapAndStops(t *testing.T) {
	h := newHarness(t, false)
	if resp := h.m.Handle(Request{Cmd: "start", Tag: "cup"}); !resp.OK {
		t.Fatalf("start: %s", resp.Message)
	}

	h.expectNoAttach() // nobody on the server yet
	h.setPlayers("player")
	f := h.attach()

	h.recordMap(f, "supply", "demo0000.tv_84")
	h.advance(20 * time.Minute)
	f.say("Stopped demo.")
	h.recordMap(f, "radar", "demo0001.tv_84")

	meta := h.finished("cup_2026-10-02_213000_supply.tv_84")
	if meta.EndReason != reasonMapChange || meta.Map != "supply" || meta.Tag != "cup" {
		t.Errorf("supply metadata = %+v", meta)
	}
	eventually(t, "radar in recording.json", func() bool {
		live := loadRecording(h.cfg.recordingPath())
		return live != nil && live.Map == "radar" && live.Tag == "cup"
	})

	if resp := h.m.Handle(Request{Cmd: "stop"}); !resp.OK {
		t.Fatalf("stop: %s", resp.Message)
	}
	expectSignal(t, f, syscall.SIGTERM)
	f.say("Stopped demo.", "----- Server Shutdown (Received signal 15) -----")
	f.exit()

	meta = h.finished("cup_2026-10-02_215000_radar.tv_84")
	if meta.EndReason != reasonStop {
		t.Errorf("radar end_reason = %q, want %q", meta.EndReason, reasonStop)
	}
	eventually(t, "recording.json removed", func() bool { return !fileExists(h.cfg.recordingPath()) })
	eventually(t, "detach", func() bool { return !h.m.Status().Attached })
	if !h.m.retryAt.IsZero() {
		t.Errorf("a requested stop must not schedule a retry")
	}
}

func TestKickRespawnsWithBackoff(t *testing.T) {
	h := newHarness(t, true)
	h.setPlayers("player")
	f := h.attach()
	h.recordMap(f, "supply", "demo0000.tv_84")

	f.say("Stopped demo.", "----- Server Shutdown (Server Disconnected - was kicked) -----")
	expectSignal(t, f, syscall.SIGTERM)
	f.exit()

	meta := h.finished("2026-10-02_213000_supply.tv_84")
	if meta.EndReason != reasonDisconnect {
		t.Errorf("end_reason = %q, want %q", meta.EndReason, reasonDisconnect)
	}
	eventually(t, "detach", func() bool { return !h.m.Status().Attached })

	h.expectNoAttach() // backoff not elapsed
	h.advance(6 * time.Second)
	h.attach()
}

func TestMasterQuitSignalsOnce(t *testing.T) {
	h := newHarness(t, true)
	h.setPlayers("player")
	f := h.attach()
	h.recordMap(f, "supply", "demo0000.tv_84")

	// rcon quit: a disconnect, then the supervisor calls Shutdown.
	f.say("Stopped demo.", "----- Server Shutdown (Server disconnected) -----")
	expectSignal(t, f, syscall.SIGTERM)
	go func() {
		time.Sleep(50 * time.Millisecond)
		f.exit()
	}()
	h.m.Shutdown(reasonQuit)

	meta := h.finished("2026-10-02_213000_supply.tv_84")
	if meta.EndReason != reasonQuit {
		t.Errorf("end_reason = %q, want %q", meta.EndReason, reasonQuit)
	}
	select {
	case sig := <-f.sigs:
		t.Errorf("slave signalled twice (%v): etlded would skip closing the demo", sig)
	default:
	}
}

func TestIdleDetachIgnoresTheSlave(t *testing.T) {
	h := newHarness(t, true)

	h.setPlayers("ETLTV") // not a player
	h.expectNoAttach()

	h.setPlayers("player", "ETLTV")
	f := h.attach()
	h.recordMap(f, "supply", "demo0000.tv_84")

	h.setPlayers("ETLTV")
	h.m.tick() // starts the empty timer
	h.advance(2 * time.Minute)
	h.m.tick()
	expectSignal(t, f, syscall.SIGTERM)
	f.say("Stopped demo.", "----- Server Shutdown (Received signal 15) -----")
	f.exit()

	meta := h.finished("2026-10-02_213000_supply.tv_84")
	if meta.EndReason != reasonIdle {
		t.Errorf("end_reason = %q, want %q", meta.EndReason, reasonIdle)
	}
	eventually(t, "detach", func() bool { return !h.m.Status().Attached })
	if !h.m.Status().Armed {
		t.Error("idle detach must stay armed")
	}

	h.setPlayers("player")
	h.attach() // reattaches straight away when someone joins
}

func TestConnectTimeoutRetries(t *testing.T) {
	h := newHarness(t, true)
	h.setPlayers("player")
	f := h.attach()

	h.advance(61 * time.Second)
	h.m.tick()
	expectSignal(t, f, syscall.SIGTERM)
	f.exit()
	eventually(t, "detach", func() bool { return !h.m.Status().Attached })

	h.expectNoAttach()
	h.advance(6 * time.Second)
	h.attach()
}

func TestStateSurvivesRestart(t *testing.T) {
	h := newHarness(t, false)
	h.m.Handle(Request{Cmd: "start", Tag: "cup"})

	// The next container boot reads the same state dir.
	again := newHarnessWith(t, h.cfg)
	if s := again.m.Status(); !s.Armed || s.Tag != "cup" || s.Source != sourceStateFile {
		t.Fatalf("after restart: %+v", s)
	}

	again.m.Handle(Request{Cmd: "stop"})
	cfg := h.cfg
	cfg.Autostart = true
	third := newHarnessWith(t, cfg)
	if s := third.m.Status(); s.Armed {
		t.Fatalf("stop must win over ETLTV_AUTOSTART: %+v", s)
	}

	third.m.Handle(Request{Cmd: "reset"})
	if s := third.m.Status(); !s.Armed || s.Source != sourceEnv {
		t.Fatalf("after reset: %+v", s)
	}
}

func TestStartRejects(t *testing.T) {
	h := newHarness(t, false)
	if resp := h.m.Handle(Request{Cmd: "start", Tag: "a;b"}); resp.OK {
		t.Error("tag with shell characters accepted")
	}

	os.Remove(filepath.Join(h.cfg.BasePath, "legacy", "tvgame.mp.x86_64.so"))
	resp := h.m.Handle(Request{Cmd: "start"})
	if resp.OK || h.m.Status().Armed {
		t.Errorf("start without a tvgame module should fail: %+v", resp)
	}
}

func TestSweepsLeftoversAtBoot(t *testing.T) {
	h := newHarness(t, false)
	h.writeRaw("demo0003.tv_84")
	h.m.sweepLeftovers()

	matches, _ := filepath.Glob(filepath.Join(h.cfg.DemoDir, "*_unknown.tv_84"))
	if len(matches) != 1 {
		t.Fatalf("leftover not finalized, demo dir has %v", matches)
	}
	if meta := readMeta(matches[0]); meta.EndReason != reasonInterrupted {
		t.Errorf("end_reason = %q, want %q", meta.EndReason, reasonInterrupted)
	}
}

func TestSweptLeftoverKeepsTagAndMap(t *testing.T) {
	h := newHarness(t, false)
	started := time.Date(2026, 10, 3, 15, 33, 0, 0, time.UTC)
	saveRecording(h.cfg.recordingPath(), liveRecording{Raw: "demo0000.tv_84", Tag: "90370", Map: "te_escape2", Started: started})
	h.writeRaw("demo0000.tv_84")
	h.m.sweepLeftovers()

	meta := h.finished("90370_2026-10-03_153300_te_escape2.tv_84")
	if meta.Tag != "90370" || meta.Map != "te_escape2" || meta.EndReason != reasonInterrupted {
		t.Errorf("metadata = %+v", meta)
	}
	if fileExists(h.cfg.recordingPath()) {
		t.Error("recording.json left behind")
	}
}

// a dropped slave closes its demo, then dies in its filesystem
// restart without printing "Server Shutdown".
func TestSlaveCrashOnServerQuit(t *testing.T) {
	h := newHarness(t, true)
	h.setPlayers("player")
	f := h.attach()
	h.recordMap(f, "oasis", "demo0000.tv_84")

	f.say(`broadcast: print "Server quit"`, "Stopped demo.", "----- Initializing Filesystem --")
	f.exit()
	time.Sleep(100 * time.Millisecond)
	h.m.Shutdown(reasonQuit)

	meta := h.finished("2026-10-02_213000_oasis.tv_84")
	if meta.EndReason != reasonQuit {
		t.Errorf("end_reason = %q, want %q", meta.EndReason, reasonQuit)
	}
}

func TestSlaveCrashOnKick(t *testing.T) {
	h := newHarness(t, true)
	h.setPlayers("player")
	f := h.attach()
	h.recordMap(f, "oasis", "demo0000.tv_84")

	f.say("Stopped demo.", "----- Initializing Filesystem --")
	f.exit()

	meta := h.finished("2026-10-02_213000_oasis.tv_84")
	if meta.EndReason != reasonDisconnect {
		t.Errorf("end_reason = %q, want %q", meta.EndReason, reasonDisconnect)
	}
	eventually(t, "detach", func() bool { return !h.m.Status().Attached })
	h.advance(6 * time.Second)
	h.attach() // and it comes back
}

// etlded can deadlock in its SIGTERM handler; without SIGKILL the hung slave
// would block every reattach.
func TestHungSlaveIsKilled(t *testing.T) {
	h := newHarness(t, true)
	h.setPlayers("player")
	f := h.attach()
	h.recordMap(f, "radar", "demo0000.tv_84")

	f.say("Stopped demo.", "----- Server Shutdown (Server Disconnected - player kicked) -----")
	expectSignal(t, f, syscall.SIGTERM)
	f.say("----- Server Shutdown (Received signal 15) -----")
	expectSignal(t, f, syscall.SIGKILL)
	f.exit()

	eventually(t, "detach", func() bool { return !h.m.Status().Attached })
	h.advance(6 * time.Second)
	h.attach()
}
