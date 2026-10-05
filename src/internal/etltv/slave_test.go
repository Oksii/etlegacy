package etltv

import (
	"reflect"
	"strings"
	"testing"
)

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

func TestSlaveArgs(t *testing.T) {
	cfg := Config{
		Etlded: "/legacy/server/etlded", BasePath: "/legacy/server", StateDir: "/legacy/homepath/etltv",
		MasterPort: "27960", TVPassword: "3tltv", Hostname: "My Server", RedirectURL: "https://dl",
		Port: "27961", Name: "ETLTV", MaxClients: "10", Delay: "0", AutoRecord: "0", AutoAction: "3",
	}

	args := slaveArgs(cfg)
	joined := strings.Join(args, " ")
	for _, want := range []string{
		"+set net_ip 127.0.0.1", "+set net_enabled 1", "+set net_port 27961",
		"+set fs_homepath /legacy/homepath/etltv/home", "+set sv_etltv_autorecord 0", "+set tvg_autoAction 3",
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
