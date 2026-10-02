package etltv

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// State is what "etltv start/stop" persist across restarts.
type State struct {
	Armed bool   `json:"armed"`
	Tag   string `json:"tag,omitempty"`
}

const (
	sourceStateFile = "state file"
	sourceEnv       = "ETLTV_AUTOSTART"
)

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

// A state file, once written, wins over ETLTV_AUTOSTART.
func resolveState(file State, exists, autostart bool) (State, string) {
	if exists {
		return file, sourceStateFile
	}
	return State{Armed: autostart}, sourceEnv
}

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
