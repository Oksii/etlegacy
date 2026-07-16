package etlproto

import (
	"net"
	"strings"
	"testing"
	"time"
)

// fakeServer binds a localhost UDP socket and replies to each request with the
// packets returned by reply. It returns the address to query.
func fakeServer(t *testing.T, reply func(request []byte) [][]byte) string {
	t.Helper()

	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatalf("bind fake server: %v", err)
	}
	t.Cleanup(func() { conn.Close() })

	go func() {
		buf := make([]byte, maxPacket)
		for {
			n, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				return // closed by cleanup
			}
			for _, p := range reply(buf[:n]) {
				if _, err := conn.WriteToUDP(p, from); err != nil {
					return
				}
			}
		}
	}()

	return conn.LocalAddr().String()
}

func statusResponse(infostring string, players ...string) []byte {
	body := "statusResponse\n" + infostring + "\n"
	for _, p := range players {
		body += p + "\n"
	}
	return append(append([]byte{}, oobPrefix...), body...)
}

func playerLines(n int) []string {
	lines := make([]string, n)
	for i := range lines {
		lines[i] = `10 45 "player"`
	}
	return lines
}

const realInfostring = `\sv_maxclients\24\mapname\adlernest\sv_hostname\^7ETL ^1Server\g_gametype\2`

func TestParseStatus(t *testing.T) {
	tests := []struct {
		name        string
		resp        []byte
		wantPlayers int
		wantHost    string
		wantMap     string
		wantMax     int
		wantErr     bool
	}{
		{
			name:        "empty server",
			resp:        statusResponse(realInfostring),
			wantPlayers: 0,
			wantHost:    "ETL Server",
			wantMap:     "adlernest",
			wantMax:     24,
		},
		{
			name:        "full server",
			resp:        statusResponse(`\sv_maxclients\32\mapname\supply\sv_hostname\Test`, playerLines(32)...),
			wantPlayers: 32,
			wantHost:    "Test",
			wantMap:     "supply",
			wantMax:     32,
		},
		{
			// "^^c": the first caret is literal (next char is '^'), then "^c"
			// is a color code, matching the engine's Q_CleanStr.
			name:        "colored hostname is stripped",
			resp:        statusResponse(`\sv_hostname\^1a^2b^^c\mapname\radar\sv_maxclients\16`),
			wantPlayers: 0,
			wantHost:    "ab^",
			wantMap:     "radar",
			wantMax:     16,
		},
		{
			name:        "missing keys do not error",
			resp:        statusResponse(`\g_gametype\2`),
			wantPlayers: 0,
			wantHost:    "",
			wantMap:     "",
			wantMax:     0,
		},
		{
			name:    "empty response",
			resp:    []byte{},
			wantErr: true,
		},
		{
			name:    "wrong header",
			resp:    []byte("infoResponse\n\\sv_hostname\\x\n"),
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// ParseStatus consumes OOB-stripped payloads, as Query returns.
			resp := tc.resp
			if len(resp) >= len(oobPrefix) && string(resp[:len(oobPrefix)]) == string(oobPrefix) {
				resp = resp[len(oobPrefix):]
			}

			got, err := ParseStatus(resp)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.Players != tc.wantPlayers {
				t.Errorf("players = %d, want %d", got.Players, tc.wantPlayers)
			}
			if got.Hostname != tc.wantHost {
				t.Errorf("hostname = %q, want %q", got.Hostname, tc.wantHost)
			}
			if got.Map != tc.wantMap {
				t.Errorf("map = %q, want %q", got.Map, tc.wantMap)
			}
			if got.MaxClients != tc.wantMax {
				t.Errorf("maxclients = %d, want %d", got.MaxClients, tc.wantMax)
			}
		})
	}
}

func TestGetStatusOverUDP(t *testing.T) {
	addr := fakeServer(t, func(request []byte) [][]byte {
		if !strings.Contains(string(request), "getstatus") {
			return nil
		}
		return [][]byte{statusResponse(realInfostring, playerLines(3)...)}
	})

	got, err := GetStatus(addr, DefaultTimeout)
	if err != nil {
		t.Fatalf("GetStatus: %v", err)
	}
	if got.Players != 3 || got.Hostname != "ETL Server" || got.MaxClients != 24 {
		t.Errorf("got %+v", got)
	}
}

func TestGetStatusNoOOBPrefix(t *testing.T) {
	addr := fakeServer(t, func([]byte) [][]byte {
		return [][]byte{[]byte("statusResponse\n\\sv_hostname\\x\n")}
	})

	if _, err := GetStatus(addr, 500*time.Millisecond); err == nil {
		t.Fatal("expected error for response without OOB prefix")
	}
}

func TestGetStatusTimeout(t *testing.T) {
	addr := fakeServer(t, func([]byte) [][]byte { return nil })

	start := time.Now()
	if _, err := GetStatus(addr, 300*time.Millisecond); err == nil {
		t.Fatal("expected timeout error")
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Errorf("timeout not honored, took %v", elapsed)
	}
}

func printPacket(s string) []byte {
	return append(append([]byte{}, oobPrefix...), "print\n"+s...)
}

func TestRconSinglePacket(t *testing.T) {
	addr := fakeServer(t, func(request []byte) [][]byte {
		if !strings.Contains(string(request), "rcon secret status") {
			return nil
		}
		return [][]byte{printPacket("map: adlernest\n")}
	})

	got, err := Rcon(addr, "secret", "status", DefaultTimeout)
	if err != nil {
		t.Fatalf("Rcon: %v", err)
	}
	if got != "map: adlernest\n" {
		t.Errorf("got %q", got)
	}
}

// A single-read implementation would silently truncate this.
func TestRconMultiPacket(t *testing.T) {
	addr := fakeServer(t, func([]byte) [][]byte {
		return [][]byte{
			printPacket("part1\n"),
			printPacket("part2\n"),
			printPacket("part3\n"),
		}
	})

	got, err := Rcon(addr, "secret", "cvarlist", DefaultTimeout)
	if err != nil {
		t.Fatalf("Rcon: %v", err)
	}
	if got != "part1\npart2\npart3\n" {
		t.Errorf("got %q, want all three packets concatenated", got)
	}
}

func TestRconNoResponse(t *testing.T) {
	addr := fakeServer(t, func([]byte) [][]byte { return nil })

	if _, err := Rcon(addr, "secret", "status", 300*time.Millisecond); err == nil {
		t.Fatal("expected error when server does not reply")
	}
}

// "Bad rconpassword." comes back as a normal print packet, not an error.
func TestRconBadPasswordIsReturnedVerbatim(t *testing.T) {
	addr := fakeServer(t, func([]byte) [][]byte {
		return [][]byte{printPacket("Bad rconpassword.\n")}
	})

	got, err := Rcon(addr, "wrong", "status", DefaultTimeout)
	if err != nil {
		t.Fatalf("Rcon: %v", err)
	}
	if got != "Bad rconpassword.\n" {
		t.Errorf("got %q", got)
	}
}
