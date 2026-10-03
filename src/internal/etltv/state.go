package etltv

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

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

// The demo being written, so one left by an unclean exit keeps its tag and map.
type liveRecording struct {
	Raw     string    `json:"raw"` // demo0000.tv_84
	Tag     string    `json:"tag,omitempty"`
	Map     string    `json:"map,omitempty"`
	Started time.Time `json:"started"`
}

func loadRecording(path string) *liveRecording {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var r liveRecording
	if json.Unmarshal(data, &r) != nil {
		return nil
	}
	return &r
}

func saveRecording(path string, r liveRecording) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, data)
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
