// Command etlutil queries the local ET server or issues rcon commands. It is
// meant to be run inside the server container (docker exec), where MAP_PORT and
// RCONPASSWORD are already present in the environment.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/oksii/etlegacy/src/internal/etlproto"
)

func usage() {
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  etlutil status            Print hostname|map|players|maxclients")
	fmt.Fprintln(os.Stderr, "  etlutil rcon <command>    Run an rcon command and print the reply")
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

	default:
		usage()
	}
}

func sanitize(s string) string {
	return strings.ReplaceAll(s, "|", "/")
}
