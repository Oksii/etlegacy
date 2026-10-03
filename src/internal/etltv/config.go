package etltv

import (
	"path/filepath"
	"time"
)

const DefaultSocket = "/tmp/etlsupervisor.sock"

type Config struct {
	Etlded   string
	BasePath string
	StateDir string
	DemoDir  string // finished demos

	MasterPort     string
	MasterPassword string // the server's g_password; etltv must send it too
	TVPassword     string // the server's sv_etltv_password
	MaxSlaves      string // the server's sv_etltv_maxslaves
	Hostname       string
	RedirectURL    string
	ServerIP       string

	Autostart      bool
	Public         bool
	Port           string
	Name           string
	MaxClients     string
	ViewerPassword string
	Delay          string
	IdleDetach     time.Duration // 0 never detaches

	UploadURL   string
	UploadToken string
}

func (c Config) statePath() string { return filepath.Join(c.StateDir, "state") }

func (c Config) recordingPath() string { return filepath.Join(c.StateDir, "recording.json") }

// Separate from the server's, so the two never write the same etconfig.cfg.
func (c Config) homePath() string { return filepath.Join(c.StateDir, "home") }
