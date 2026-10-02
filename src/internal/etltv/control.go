package etltv

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"time"
)

// Request is one control command: "start" (with an optional tag), "stop",
// "reset" or "status".
type Request struct {
	Cmd string `json:"cmd"`
	Tag string `json:"tag,omitempty"`
}

// Response answers a Request. Message is a single human-readable line, which
// is what etlutil prints and the Lua hook relays to the rcon caller.
type Response struct {
	OK      bool        `json:"ok"`
	Message string      `json:"message"`
	Status  *StatusInfo `json:"status,omitempty"`
}

// StatusInfo describes the recorder.
type StatusInfo struct {
	Armed  bool   `json:"armed"`
	Source string `json:"source"` // what decided Armed: the state file or ETLTV_AUTOSTART
	Tag    string `json:"tag,omitempty"`
	Name   string `json:"name"` // the slave's client name on the master
	// Attached is true while a slave process runs, whether it is still
	// connecting or already recording.
	Attached  bool      `json:"attached"`
	Recording string    `json:"recording,omitempty"`
	Map       string    `json:"map,omitempty"`
	Since     time.Time `json:"since,omitempty"`
}

// Listen serves control requests on a unix socket at path, replacing any stale
// socket left by a previous run.
func Listen(path string, handle func(Request) Response) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	l, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return // listener closed
			}
			go serveConn(conn, handle)
		}
	}()
	return l, nil
}

func serveConn(conn net.Conn, handle func(Request) Response) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))

	var req Request
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		json.NewEncoder(conn).Encode(Response{Message: fmt.Sprintf("bad request: %v", err)})
		return
	}
	json.NewEncoder(conn).Encode(handle(req))
}

// Call sends one request to the supervisor.
func Call(path string, req Request, timeout time.Duration) (Response, error) {
	conn, err := net.DialTimeout("unix", path, timeout)
	if err != nil {
		return Response{}, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(timeout))

	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return Response{}, err
	}
	var resp Response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return Response{}, err
	}
	return resp, nil
}
