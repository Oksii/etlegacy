// Package etlproto implements the ET out-of-band (OOB) UDP protocol used to
// query a running server and to issue rcon commands.
package etlproto

import (
	"bytes"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultTimeout = 3 * time.Second
	rconIdle       = 250 * time.Millisecond
	maxPacket      = 16384
)

var oobPrefix = []byte{0xFF, 0xFF, 0xFF, 0xFF}

type Status struct {
	Hostname   string
	Map        string
	Players    int
	MaxClients int
}

// OOBPacket builds \xFF\xFF\xFF\xFF<payload>\n.
func OOBPacket(payload string) []byte {
	p := make([]byte, 0, len(oobPrefix)+len(payload)+1)
	p = append(p, oobPrefix...)
	p = append(p, payload...)
	return append(p, '\n')
}

func Query(addr, request string, timeout time.Duration) ([]byte, error) {
	udpAddr, err := net.ResolveUDPAddr("udp4", addr)
	if err != nil {
		return nil, fmt.Errorf("resolve %s: %w", addr, err)
	}
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil, fmt.Errorf("create socket: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(timeout))

	if _, err := conn.WriteToUDP(OOBPacket(request), udpAddr); err != nil {
		return nil, fmt.Errorf("send %s: %w", request, err)
	}

	buf := make([]byte, maxPacket)
	n, _, err := conn.ReadFromUDP(buf)
	if err != nil {
		return nil, fmt.Errorf("read %s response: %w", request, err)
	}
	if n < len(oobPrefix) || !bytes.HasPrefix(buf[:n], oobPrefix) {
		return nil, fmt.Errorf("malformed %s response (%d bytes, no OOB prefix)", request, n)
	}
	return buf[len(oobPrefix):n], nil
}

func GetStatus(addr string, timeout time.Duration) (Status, error) {
	resp, err := Query(addr, "getstatus", timeout)
	if err != nil {
		return Status{}, err
	}
	return ParseStatus(resp)
}

// statusResponse\n\key\value\...\n<player>\n<player>\n
func ParseStatus(resp []byte) (Status, error) {
	lines := strings.Split(string(resp), "\n")
	if len(lines) < 2 {
		return Status{}, fmt.Errorf("unexpected response format (%d lines)", len(lines))
	}
	if strings.TrimSpace(lines[0]) != "statusResponse" {
		return Status{}, fmt.Errorf("unexpected response header %q", lines[0])
	}

	info := ParseInfoString(lines[1])
	s := Status{
		Hostname: StripColors(info["sv_hostname"]),
		Map:      info["mapname"],
	}
	s.MaxClients, _ = strconv.Atoi(info["sv_maxclients"])

	// Each remaining non-empty line is one connected client.
	for _, line := range lines[2:] {
		if strings.TrimSpace(line) != "" {
			s.Players++
		}
	}
	return s, nil
}

func ParseInfoString(s string) map[string]string {
	info := make(map[string]string)
	fields := strings.Split(strings.TrimPrefix(s, "\\"), "\\")
	for i := 0; i+1 < len(fields); i += 2 {
		info[fields[i]] = fields[i+1]
	}
	return info
}

func StripColors(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '^' && i+1 < len(s) && s[i+1] != '^' {
			i++
			continue
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func Rcon(addr, password, command string, timeout time.Duration) (string, error) {
	udpAddr, err := net.ResolveUDPAddr("udp4", addr)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", addr, err)
	}
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return "", fmt.Errorf("create socket: %w", err)
	}
	defer conn.Close()

	deadline := time.Now().Add(timeout)
	conn.SetDeadline(deadline)

	if _, err := conn.WriteToUDP(OOBPacket("rcon "+password+" "+command), udpAddr); err != nil {
		return "", fmt.Errorf("send rcon: %w", err)
	}

	var out strings.Builder
	buf := make([]byte, maxPacket)
	for {
		// The first packet gets the full timeout; later ones only need to beat
		// the idle window, which is what terminates the loop.
		wait := timeout
		if out.Len() > 0 {
			wait = rconIdle
		}
		if d := time.Now().Add(wait); d.Before(deadline) {
			conn.SetReadDeadline(d)
		} else {
			conn.SetReadDeadline(deadline)
		}

		n, _, err := conn.ReadFromUDP(buf)
		if err != nil {
			if nerr, ok := err.(net.Error); ok && nerr.Timeout() {
				break
			}
			return "", fmt.Errorf("read rcon response: %w", err)
		}

		payload := buf[:n]
		if !bytes.HasPrefix(payload, oobPrefix) {
			continue
		}
		payload = bytes.TrimPrefix(payload[len(oobPrefix):], []byte("print\n"))
		out.Write(payload)
	}

	if out.Len() == 0 {
		return "", fmt.Errorf("no rcon response from %s", addr)
	}
	return out.String(), nil
}
