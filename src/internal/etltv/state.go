package etltv

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// State is what "etltv start/stop" persist. It lives on the homepath volume so
// it survives the "rcon quit" restart that happens before every match.
type State struct {
	Armed bool   `json:"armed"`
	Tag   string `json:"tag,omitempty"`
}

const (
	sourceStateFile = "state file"
	sourceEnv       = "ETLTV_AUTOSTART"
)

// loadState reads the persisted state. A missing file is not an error: no
// command has been run yet, so ETLTV_AUTOSTART decides.
func loadState(path string) (s State, exists bool, err error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return State{}, false, nil
	}
	if err != nil {
		return State{}, false, err
	}
	if err := json.Unmarshal(data, &s); err != nil {
		return State{}, false, err
	}
	return s, true, nil
}

func saveState(path string, s State) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data)
}

// resolveState picks the effective state. Once a command has written the state
// file it wins over the env, so "etltv stop" holds on a server that has
// ETLTV_AUTOSTART=true until "etltv start" or "etltv reset".
func resolveState(file State, exists, autostart bool) (State, string) {
	if exists {
		return file, sourceStateFile
	}
	return State{Armed: autostart}, sourceEnv
}

// writeFileAtomic writes beside path and renames, so readers never see a
// partial file.
func writeFileAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}
