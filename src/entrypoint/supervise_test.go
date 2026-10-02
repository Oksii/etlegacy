package main

import (
	"os"
	"sync"
	"syscall"
	"testing"
	"time"
)

// There must be only one reaper per process (the supervisor creates exactly
// one): a second would collect the first one's children and drop their
// statuses. Tests share this one.
var (
	sharedKids     *children
	sharedKidsOnce sync.Once
)

func testKids() *children {
	sharedKidsOnce.Do(func() { sharedKids = newChildren() })
	return sharedKids
}

func waitExit(t *testing.T, ch <-chan syscall.WaitStatus) syscall.WaitStatus {
	t.Helper()
	select {
	case ws := <-ch:
		return ws
	case <-time.After(5 * time.Second):
		t.Fatal("exit status never delivered")
		return 0
	}
}

func TestChildrenDeliversExitStatus(t *testing.T) {
	kids := testKids()
	attr := &os.ProcAttr{Files: []*os.File{nil, os.Stdout, os.Stderr}}

	tests := []struct {
		script string
		want   int
	}{
		{"exit 0", 0},
		{"exit 3", 3},
		// Matches what a shell reports, so a crashed server keeps a
		// distinguishable exit code.
		{"kill -TERM $$", 128 + int(syscall.SIGTERM)},
	}
	for _, tc := range tests {
		_, ch, err := kids.start([]string{"/bin/sh", "-c", tc.script}, attr)
		if err != nil {
			t.Fatalf("start %q: %v", tc.script, err)
		}
		if got := exitCode(waitExit(t, ch)); got != tc.want {
			t.Errorf("%q: exit code %d, want %d", tc.script, got, tc.want)
		}
	}
}

// Children that exit before start returns must still have their status
// delivered rather than being reaped unregistered.
func TestChildrenImmediateExit(t *testing.T) {
	kids := testKids()
	attr := &os.ProcAttr{Files: []*os.File{nil, nil, nil}}

	var chans []<-chan syscall.WaitStatus
	for i := 0; i < 50; i++ {
		_, ch, err := kids.start([]string{"/bin/true"}, attr)
		if err != nil {
			t.Fatalf("start: %v", err)
		}
		chans = append(chans, ch)
	}
	for _, ch := range chans {
		if got := exitCode(waitExit(t, ch)); got != 0 {
			t.Errorf("exit code %d, want 0", got)
		}
	}
}

// The returned pid must be the child's real pid: signalling it has to reach
// that child and nothing else.
func TestChildrenReturnsRealPid(t *testing.T) {
	kids := testKids()
	pid, ch, err := kids.start([]string{"/bin/sleep", "30"}, &os.ProcAttr{Files: []*os.File{nil, nil, nil}})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if pid <= 0 {
		t.Fatalf("pid = %d", pid)
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		t.Fatalf("kill %d: %v", pid, err)
	}
	ws := waitExit(t, ch)
	if !ws.Signaled() || ws.Signal() != syscall.SIGTERM {
		t.Errorf("child not ended by our SIGTERM: %v", ws)
	}
}

func TestSlaveProcRefusesNonPositivePid(t *testing.T) {
	p := &slaveProc{pid: -1, done: make(chan struct{})}
	if err := p.Signal(syscall.SIGTERM); err == nil {
		t.Fatal("signalled pid -1")
	}
}

func TestDefaultETLTVPort(t *testing.T) {
	tests := map[string]string{
		"27960": "27970",
		"27963": "27973",
		"":      "27970", // MAP_PORT unset or unparsable: the engine default
		"abc":   "27970",
	}
	for in, want := range tests {
		if got := defaultETLTVPort(in); got != want {
			t.Errorf("defaultETLTVPort(%q) = %q, want %q", in, got, want)
		}
	}
}
