package etltv

import (
	"regexp"
	"strings"
)

// slaveArgs is the argv for the slave. etlded quotes any argument containing
// spaces when it rebuilds its command line, so values are passed as-is.
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
		set("net_enabled", "1") // IPv4 only, so nothing binds a public v6 address
	}
	set("net_port", c.Port)
	set("sv_maxclients", c.MaxClients)
	set("sv_hostname", c.Hostname+" ^7[TV]")
	set("sv_advert", "0") // keep the slave off master lists and trackers
	set("sv_wwwBaseURL", c.RedirectURL)
	set("sv_wwwDownload", "1")
	set("g_password", c.ViewerPassword)
	set("sv_etltv_autorecord", "1")
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
	evNone      eventKind = iota
	evInit                // "----- Server Initialization ----", the slave is loading a map
	evMap                 // "Server: <map>", printed right after evInit
	evRecording           // "Recording to tvdemos/demo0000.tv_84."
	evStopped             // "Stopped demo."
	evShutdown            // "----- Server Shutdown (<reason>) -----"
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

// cleanLine strips the server-time column and the ANSI colors (com_ansiColor)
// that etlded adds to its console output.
func cleanLine(line string) string {
	line = ansiEscape.ReplaceAllString(line, "")
	line = timePrefix.ReplaceAllString(line, "")
	return strings.TrimRight(line, "\r\n ")
}

// parseLine recognises the slave console lines that drive the recorder.
// Chat and other relayed text always carries a "name: " prefix, so it cannot
// pass for one of these.
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

// End reasons recorded with each demo.
const (
	reasonMapChange   = "map_change"
	reasonStop        = "stop"
	reasonQuit        = "quit"
	reasonIdle        = "idle"
	reasonDisconnect  = "disconnect"
	reasonShutdown    = "shutdown"
	reasonInterrupted = "interrupted"
)

// shutdownReason maps the slave's shutdown message to an end reason. When the
// master shuts down (rcon quit, crash) it sends a bare "disconnect", which the
// slave reports as "Server disconnected". A kick or drop carries the reason:
// "Server Disconnected - <reason>".
func shutdownReason(msg string) string {
	if msg == "Server disconnected" {
		return reasonQuit
	}
	return reasonDisconnect
}
