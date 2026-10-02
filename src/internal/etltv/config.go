// Package etltv runs an ETLTV slave beside the match server so matches can be
// recorded as .tv demos and, optionally, relayed to spectators.
//
// The slave is a second etlded that connects to the local server with
// "tv connect" and records with sv_etltv_autorecord, which yields one demo per
// map. The supervisor (PID 1) owns the slave process; operators arm and disarm
// it through a unix socket, via "etlutil tv" or rcon through the Lua hook.
package etltv

import (
	"path/filepath"
	"time"
)

// DefaultSocket is where the supervisor listens for control requests.
const DefaultSocket = "/tmp/etlsupervisor.sock"

// Config describes the slave and where its demos go.
type Config struct {
	Etlded   string // etlded binary, shared with the master
	BasePath string // fs_basepath, shared with the master so the slave has the same paks
	StateDir string // holds the sticky state file and the slave's own homepath
	DemoDir  string // finished demos

	MasterPort     string
	MasterPassword string // the master's g_password; the slave must send it too
	TVPassword     string // the master's sv_etltv_password
	MaxSlaves      string // the master's sv_etltv_maxslaves
	Hostname       string
	RedirectURL    string
	ServerIP       string

	Autostart      bool
	Public         bool
	Port           string
	Name           string // sv_etltv_clientname, how the slave shows up on the master
	MaxClients     string
	ViewerPassword string
	Delay          string
	IdleDetach     time.Duration // 0 never detaches

	UploadURL   string
	UploadToken string
}

func (c Config) statePath() string { return filepath.Join(c.StateDir, "state") }

// homePath is the slave's fs_homepath. It is kept apart from the master's so
// the two processes never write the same etconfig.cfg.
func (c Config) homePath() string { return filepath.Join(c.StateDir, "home") }
