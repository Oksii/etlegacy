package etltv

import (
	"regexp"
	"strings"
)

func slaveArgs(c Config) []string {
	ip := "127.0.0.1"
	if c.Public {
		ip = "0.0.0.0"
	}

	args := []string{c.Etlded}
	set := func(cvar, value string) {
		if value != "" {
			args = append(args, "+set", cvar, value)
		}
	}
	set("fs_basepath", c.BasePath)
	set("fs_homepath", c.homePath())
	set("net_ip", ip)
	if !c.Public {
		set("net_enabled", "1") // IPv4 only
	}
	set("net_port", c.Port)
	set("sv_maxclients", c.MaxClients)
	set("sv_hostname", c.Hostname+" ^7[TV]")
	set("sv_advert", "0") // keep the slave off master lists and trackers
	set("sv_wwwBaseURL", c.RedirectURL)
	set("sv_wwwDownload", "1")
	set("g_password", c.ViewerPassword)
	set("sv_etltv_autorecord", c.AutoRecord)
	set("tvg_autoAction", c.AutoAction)
	set("sv_etltv_clientname", c.Name)
	set("sv_etltv_delay", c.Delay) // CVAR_INIT, so it only takes effect from the command line

	args = append(args, "+tv", "connect", "127.0.0.1:"+c.MasterPort, c.TVPassword)
	if c.MasterPassword != "" {
		args = append(args, c.MasterPassword)
	}
	return args
}

type eventKind int

const (
	evNone eventKind = iota
	evInit
	evMap
	evRecording
	evStopped
	evShutdown
)

type event struct {
	kind  eventKind
	value string
}

var (
	ansiEscape = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
	// Com_Printf starts every line with the server time as "%8i ".
	timePrefix = regexp.MustCompile(`^ *-?[0-9]+ `)
)

func cleanLine(line string) string {
	line = ansiEscape.ReplaceAllString(line, "")
	line = timePrefix.ReplaceAllString(line, "")
	return strings.TrimRight(line, "\r\n ")
}

func parseLine(line string) event {
	line = cleanLine(line)
	switch {
	case strings.HasPrefix(line, "----- Server Initialization"):
		return event{kind: evInit}
	case strings.HasPrefix(line, "Server: "):
		return event{evMap, strings.TrimPrefix(line, "Server: ")}
	case strings.HasPrefix(line, "Recording to "):
		return event{evRecording, strings.TrimSuffix(strings.TrimPrefix(line, "Recording to "), ".")}
	case line == "Stopped demo.":
		return event{kind: evStopped}
	case strings.HasPrefix(line, "----- Server Shutdown ("):
		reason := strings.TrimPrefix(line, "----- Server Shutdown (")
		return event{evShutdown, strings.TrimSuffix(reason, ") -----")}
	}
	return event{}
}

const (
	reasonMapChange   = "map_change"
	reasonStop        = "stop"
	reasonQuit        = "quit"
	reasonIdle        = "idle"
	reasonDisconnect  = "disconnect"
	reasonShutdown    = "shutdown"
	reasonInterrupted = "interrupted"
)

func shutdownReason(msg string) string {
	if msg == "Server disconnected" {
		return reasonQuit
	}
	return reasonDisconnect
}
