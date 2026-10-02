package etltv

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"time"
)

// Request is one control command: "start" (optional tag), "stop", "reset" or "status".
type Request struct {
	Cmd string `json:"cmd"`
	Tag string `json:"tag,omitempty"`
}

type Response struct {
	OK      bool        `json:"ok"`
	Message string      `json:"message"`
	Status  *StatusInfo `json:"status,omitempty"`
}

type StatusInfo struct {
	Armed     bool      `json:"armed"`
	Source    string    `json:"source"`
	Tag       string    `json:"tag,omitempty"`
	Name      string    `json:"name"`
	Attached  bool      `json:"attached"`
	Recording string    `json:"recording,omitempty"`
	Map       string    `json:"map,omitempty"`
	Since     time.Time `json:"since,omitempty"`
}

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
