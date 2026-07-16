package main

import (
	"fmt"
	"os"
	"strconv"
	"syscall"
	"time"

	"github.com/oksii/etlegacy/src/internal/etlproto"
)

func main() {
	port := os.Getenv("MAP_PORT")
	if port == "" {
		port = "27960"
	}
	addr := "127.0.0.1:" + port

	// Maximum number of active players that still allows a restart.
	// Default 0: only restart when server is completely empty.
	maxPlayers, _ := strconv.Atoi(os.Getenv("AUTORESTART_PLAYERS"))
	interval := 0
	if len(os.Args) > 1 {
		interval, _ = strconv.Atoi(os.Args[1])
	}

	if interval > 0 {
		fmt.Printf("Autorestart daemon started (interval: %dm, max players: %d)\n", interval, maxPlayers)
		// Wait for the server to finish starting before the first check.
		time.Sleep(30 * time.Second)
		ticker := time.NewTicker(time.Duration(interval) * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			check(addr, port, maxPlayers)
		}
	} else {
		// exit code 0 = restart triggered, 1 = skipped/error.
		os.Exit(check(addr, port, maxPlayers))
	}
}

// check queries the server and sends SIGTERM to PID 1 if the player count is
// at or below the threshold.
func check(addr, port string, maxPlayers int) int {
	status, err := etlproto.GetStatus(addr, etlproto.DefaultTimeout)
	if err != nil {
		fmt.Printf("Failed to query server on port %s: %v\n", port, err)
		return 1
	}

	fmt.Printf("Current player count: %d\n", status.Players)

	if status.Players > maxPlayers {
		fmt.Printf("Players active (%d/%d). Skipping restart.\n", status.Players, maxPlayers)
		return 1
	}

	fmt.Println("Player threshold met. Restarting server.")
	if err := syscall.Kill(1, syscall.SIGTERM); err != nil {
		fmt.Printf("Failed to signal server: %v\n", err)
		return 1
	}
	fmt.Println("SIGTERM sent. Server will restart.")
	return 0
}
