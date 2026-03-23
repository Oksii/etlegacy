package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// oobPacket: \xFF\xFF\xFF\xFF<name>\n
func oobPacket(name string) []byte {
	return append([]byte{0xFF, 0xFF, 0xFF, 0xFF}, append([]byte(name), '\n')...)
}

// queryPlayerCount sends a getstatus OOB packet and returns the number of
// connected players by counting non-empty player lines in the response.
func queryPlayerCount(addr string, timeout time.Duration) (int, error) {
	udpAddr, err := net.ResolveUDPAddr("udp4", addr)
	if err != nil {
		return 0, fmt.Errorf("resolve %s: %w", addr, err)
	}
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return 0, fmt.Errorf("create socket: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(timeout))

	if _, err := conn.WriteToUDP(oobPacket("getstatus"), udpAddr); err != nil {
		return 0, fmt.Errorf("send getstatus: %w", err)
	}

	buf := make([]byte, 16384)
	n, _, err := conn.ReadFromUDP(buf)
	if err != nil {
		return 0, fmt.Errorf("read getstatus response: %w", err)
	}

	// Response: \xFF\xFF\xFF\xFFstatusResponse\n<infostring>\n<player>...
	lines := strings.Split(string(buf[:n]), "\n")
	if len(lines) < 2 {
		return 0, fmt.Errorf("unexpected response format (%d lines)", len(lines))
	}
	count := 0
	for _, line := range lines[2:] {
		if strings.TrimSpace(line) != "" {
			count++
		}
	}
	return count, nil
}

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
	playerCount, err := queryPlayerCount(addr, 3*time.Second)
	if err != nil {
		fmt.Printf("Failed to query server on port %s: %v\n", port, err)
		return 1
	}

	fmt.Printf("Current player count: %d\n", playerCount)

	if playerCount > maxPlayers {
		fmt.Printf("Players active (%d/%d). Skipping restart.\n", playerCount, maxPlayers)
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
