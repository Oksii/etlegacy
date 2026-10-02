// Command etlutil queries the local ET server or issues rcon commands. It is
// meant to be run inside the server container (docker exec), where MAP_PORT and
// RCONPASSWORD are already present in the environment.
package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/oksii/etlegacy/src/internal/etlproto"
	"github.com/oksii/etlegacy/src/internal/etltv"
)

func usage() {
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  etlutil status            Print hostname|map|players|maxclients")
	fmt.Fprintln(os.Stderr, "  etlutil rcon <command>    Run an rcon command and print the reply")
	fmt.Fprintln(os.Stderr, "  etlutil tv start [tag]    Arm ETLTV recording (persists across restarts)")
	fmt.Fprintln(os.Stderr, "  etlutil tv stop           Disarm ETLTV recording and save the current demo")
	fmt.Fprintln(os.Stderr, "  etlutil tv status         Show the ETLTV recorder state")
	fmt.Fprintln(os.Stderr, "  etlutil tv reset          Forget start/stop and fall back to ETLTV_AUTOSTART")
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}

	port := os.Getenv("MAP_PORT")
	if port == "" {
		port = "27960"
	}
	addr := "127.0.0.1:" + port

	switch os.Args[1] {
	case "status":
		status, err := etlproto.GetStatus(addr, etlproto.DefaultTimeout)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to query server on port %s: %v\n", port, err)
			os.Exit(1)
		}
		// Callers split this on '|', so the field separator must not appear
		// inside a hostname or map name.
		fmt.Printf("%s|%s|%d|%d\n",
			sanitize(status.Hostname),
			sanitize(status.Map),
			status.Players,
			status.MaxClients,
		)

	case "rcon":
		if len(os.Args) < 3 {
			usage()
		}
		password := os.Getenv("RCONPASSWORD")
		if password == "" {
			fmt.Fprintln(os.Stderr, "RCONPASSWORD is not set for this server")
			os.Exit(1)
		}
		reply, err := etlproto.Rcon(addr, password, strings.Join(os.Args[2:], " "), etlproto.DefaultTimeout)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to execute rcon command on port %s: %v\n", port, err)
			os.Exit(1)
		}
		fmt.Print(reply)

	case "tv":
		tv(os.Args[2:])

	default:
		usage()
	}
}

// tv forwards a command to the supervisor's ETLTV recorder. The Lua rcon hook
// runs it from inside a server frame, hence the short timeout.
func tv(args []string) {
	if len(args) == 0 {
		usage()
	}
	req := etltv.Request{Cmd: args[0]}
	switch {
	case req.Cmd == "start" && len(args) <= 2:
		if len(args) == 2 {
			req.Tag = args[1]
		}
	case (req.Cmd == "stop" || req.Cmd == "status" || req.Cmd == "reset") && len(args) == 1:
	default:
		usage()
	}

	resp, err := etltv.Call(etltv.DefaultSocket, req, 2*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ETLTV: supervisor not reachable on %s: %v\n", etltv.DefaultSocket, err)
		os.Exit(1)
	}
	fmt.Println(resp.Message)
	if !resp.OK {
		os.Exit(1)
	}
}

func sanitize(s string) string {
	return strings.ReplaceAll(s, "|", "/")
}
