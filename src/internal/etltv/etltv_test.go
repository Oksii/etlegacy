package etltv

import (
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestSanitize(t *testing.T) {
	tests := map[string]string{
		"gather-1234":     "gather-1234",
		"Cup Final #2":    "Cup-Final-2",
		"../../etc":       "etc",
		"..":              "",
		"a;rm -rf /":      "a-rm--rf",
		"^1red^7map":      "1red-7map",
		".hidden":         "hidden",
		"etl_sp_delivery": "etl_sp_delivery",
	}
	for in, want := range tests {
		if got := Sanitize(in); got != want {
			t.Errorf("Sanitize(%q) = %q, want %q", in, got, want)
		}
	}
	if got := Sanitize(strings.Repeat("a", 100)); len(got) != 64 {
		t.Errorf("long input not capped: len %d", len(got))
	}
}

func TestDemoName(t *testing.T) {
	at := time.Date(2026, 10, 2, 21, 30, 12, 0, time.UTC)
	tests := []struct {
		tag, mapName, want string
	}{
		{"", "supply", "2026-10-02_213012_supply.tv_84"},
		{"gather-1234", "supply", "gather-1234_2026-10-02_213012_supply.tv_84"},
		{"", "", "2026-10-02_213012_unknown.tv_84"},
		{"x y", "a/b", "x-y_2026-10-02_213012_a-b.tv_84"},
	}
	for _, tc := range tests {
		if got := demoName(tc.tag, tc.mapName, ".tv_84", at); got != tc.want {
			t.Errorf("demoName(%q, %q) = %q, want %q", tc.tag, tc.mapName, got, tc.want)
		}
	}
}

func TestResolveState(t *testing.T) {
	tests := []struct {
		name       string
		file       State
		exists     bool
		autostart  bool
		wantArmed  bool
		wantSource string
	}{
		{"no file, env off", State{}, false, false, false, sourceEnv},
		{"no file, env on", State{}, false, true, true, sourceEnv},
		{"armed file beats env off", State{Armed: true}, true, false, true, sourceStateFile},
		// "etltv stop" must hold on an ETLTV_AUTOSTART=true server.
		{"disarmed file beats env on", State{}, true, true, false, sourceStateFile},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, source := resolveState(tc.file, tc.exists, tc.autostart)
			if got.Armed != tc.wantArmed || source != tc.wantSource {
				t.Errorf("got armed=%v source=%q, want armed=%v source=%q", got.Armed, source, tc.wantArmed, tc.wantSource)
			}
		})
	}
}

func TestStateRoundTrip(t *testing.T) {
	path := t.TempDir() + "/etltv/state"
	if _, exists, err := loadState(path); exists || err != nil {
		t.Fatalf("missing file: exists=%v err=%v", exists, err)
	}
	want := State{Armed: true, Tag: "cup"}
	if err := saveState(path, want); err != nil {
		t.Fatalf("saveState: %v", err)
	}
	got, exists, err := loadState(path)
	if err != nil || !exists || got != want {
		t.Fatalf("loadState = %+v, %v, %v; want %+v", got, exists, err, want)
	}
}

func TestParseLine(t *testing.T) {
	tests := []struct {
		line string
		want event
	}{
		{"----- Server Initialization ----", event{kind: evInit}},
		{"Server: supply", event{evMap, "supply"}},
		{"Recording to tvdemos/demo0000.tv_84.", event{evRecording, "tvdemos/demo0000.tv_84"}},
		{"Stopped demo.\r", event{kind: evStopped}},
		{"----- Server Shutdown (Server disconnected) -----", event{evShutdown, "Server disconnected"}},
		{"----- Server Shutdown (Server Disconnected - was kicked) -----", event{evShutdown, "Server Disconnected - was kicked"}},
		{"----- Server Shutdown (Received signal 15) -----", event{evShutdown, "Received signal 15"}},
		// Real etlded output: server-time column and ANSI colors.
		{"     200 Recording to tvdemos/demo0000.tv_84.\x1b[0m", event{evRecording, "tvdemos/demo0000.tv_84"}},
		{"       0 ----- Server Initialization ----\x1b[0m", event{kind: evInit}},
		{"       0 Server: radar\x1b[0m", event{evMap, "radar"}},
		{"   41250 \x1b[1;33mStopped demo.\x1b[0m", event{kind: evStopped}},
		{"       0 ----- Database Initialization --\x1b[0m", event{}},
		// Relayed chat always has a name prefix.
		{"player: Stopped demo.", event{}},
		{"Hunk_Clear: reset the hunk ok", event{}},
	}
	for _, tc := range tests {
		if got := parseLine(tc.line); got != tc.want {
			t.Errorf("parseLine(%q) = %+v, want %+v", tc.line, got, tc.want)
		}
	}
}

func TestShutdownReason(t *testing.T) {
	if got := shutdownReason("Server disconnected"); got != reasonQuit {
		t.Errorf("master shutdown = %q, want %q", got, reasonQuit)
	}
	if got := shutdownReason("Server Disconnected - was kicked"); got != reasonDisconnect {
		t.Errorf("kick = %q, want %q", got, reasonDisconnect)
	}
}

func TestSlaveArgs(t *testing.T) {
	cfg := Config{
		Etlded: "/legacy/server/etlded", BasePath: "/legacy/server", StateDir: "/legacy/homepath/etltv",
		MasterPort: "27960", TVPassword: "3tltv", Hostname: "My Server", RedirectURL: "https://dl",
		Port: "27961", Name: "ETLTV", MaxClients: "10", Delay: "0",
	}

	args := slaveArgs(cfg)
	joined := strings.Join(args, " ")
	for _, want := range []string{
		"+set net_ip 127.0.0.1", "+set net_enabled 1", "+set net_port 27961",
		"+set fs_homepath /legacy/homepath/etltv/home", "+set sv_etltv_autorecord 1",
		"+set sv_hostname My Server ^7[TV]",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("args missing %q:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "g_password") {
		t.Errorf("empty viewer password should not be set:\n%s", joined)
	}
	if tail := args[len(args)-4:]; !reflect.DeepEqual(tail, []string{"+tv", "connect", "127.0.0.1:27960", "3tltv"}) {
		t.Errorf("connect args = %q", tail)
	}

	cfg.Public, cfg.MasterPassword, cfg.ViewerPassword = true, "war", "watch"
	args = slaveArgs(cfg)
	joined = strings.Join(args, " ")
	if !strings.Contains(joined, "+set net_ip 0.0.0.0") || strings.Contains(joined, "net_enabled") {
		t.Errorf("public slave should bind all interfaces:\n%s", joined)
	}
	if !strings.Contains(joined, "+set g_password watch") {
		t.Errorf("viewer password not set:\n%s", joined)
	}
	if last := args[len(args)-1]; last != "war" {
		t.Errorf("master password should be the last connect arg, got %q", last)
	}
}

func TestControlRoundTrip(t *testing.T) {
	sock := t.TempDir() + "/ctl.sock"
	l, err := Listen(sock, func(req Request) Response {
		return Response{OK: true, Message: req.Cmd + ":" + req.Tag}
	})
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer l.Close()

	resp, err := Call(sock, Request{Cmd: "start", Tag: "cup"}, time.Second)
	if err != nil {
		t.Fatalf("Call: %v", err)
	}
	if !resp.OK || resp.Message != "start:cup" {
		t.Errorf("got %+v", resp)
	}
}
