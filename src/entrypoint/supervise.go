package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/oksii/etlegacy/src/internal/etlproto"
	"github.com/oksii/etlegacy/src/internal/etltv"
)

type children struct {
	mu      sync.Mutex
	waiters map[int]chan syscall.WaitStatus
}

func newChildren() *children {
	c := &children{waiters: map[int]chan syscall.WaitStatus{}}
	sigchld := make(chan os.Signal, 1)
	signal.Notify(sigchld, syscall.SIGCHLD)
	go func() {
		for range sigchld {
			c.reap()
		}
	}()
	return c
}

func (c *children) start(argv []string, attr *os.ProcAttr) (int, <-chan syscall.WaitStatus, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	p, err := os.StartProcess(argv[0], argv, attr)
	if err != nil {
		return 0, nil, err
	}
	// Release sets p.Pid to -1, so keep the pid first: kill(-1) would signal
	// every process in the container.
	pid := p.Pid
	ch := make(chan syscall.WaitStatus, 1)
	c.waiters[pid] = ch
	p.Release() // we reap it ourselves; signals go by pid
	return pid, ch, nil
}

func (c *children) reap() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for {
		var ws syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
		if pid <= 0 || err != nil {
			return
		}
		if ch, ok := c.waiters[pid]; ok {
			ch <- ws
			delete(c.waiters, pid)
		}
	}
}

func isTerminal(f *os.File) bool {
	var t syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TCGETS, uintptr(unsafe.Pointer(&t)))
	return errno == 0
}

func exitCode(ws syscall.WaitStatus) int {
	if ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ws.ExitStatus()
}

type slaveProc struct {
	pid  int
	done chan struct{}
}

func (p *slaveProc) Signal(sig syscall.Signal) error {
	if p.pid <= 0 {
		// kill(0) and kill(-1) would hit the server too.
		return fmt.Errorf("refusing to signal pid %d", p.pid)
	}
	select {
	case <-p.done:
		return os.ErrProcessDone
	default:
		return syscall.Kill(p.pid, sig)
	}
}

func (p *slaveProc) Done() <-chan struct{} { return p.done }

const slaveNice = 10

func lowerPriority(pid, ref, delta int) error {
	// The raw getpriority syscall returns 20-nice to stay positive.
	prio, err := syscall.Getpriority(syscall.PRIO_PROCESS, ref)
	if err != nil {
		return err
	}
	nice := 20 - prio + delta
	if nice > 19 {
		nice = 19
	}
	return syscall.Setpriority(syscall.PRIO_PROCESS, pid, nice)
}

func etltvConfig(conf map[string]string) etltv.Config {
	idle, _ := strconv.Atoi(conf["ETLTV_IDLE_DETACH"])
	return etltv.Config{
		Etlded:         gameBase + "/etlded",
		BasePath:       gameBase,
		StateDir:       homepath + "/etltv",
		DemoDir:        conf["ETLTV_DEMO_DIR"],
		MasterPort:     conf["MAP_PORT"],
		MasterPassword: conf["PASSWORD"],
		TVPassword:     conf["ETLTVPASSWORD"],
		MaxSlaves:      conf["ETLTVMAXSLAVES"],
		Hostname:       conf["HOSTNAME"],
		RedirectURL:    conf["REDIRECTURL"],
		ServerIP:       conf["MAP_IP"],
		Autostart:      parseBoolValue(conf["ETLTV_AUTOSTART"], false),
		Public:         parseBoolValue(conf["ETLTV_PUBLIC"], false),
		Port:           conf["ETLTV_PORT"],
		Name:           conf["ETLTV_NAME"],
		MaxClients:     conf["ETLTV_MAXCLIENTS"],
		ViewerPassword: conf["ETLTV_VIEWERPASSWORD"],
		Delay:          conf["ETLTV_DELAY"],
		IdleDetach:     time.Duration(idle) * time.Second,
		UploadURL:      conf["ETLTV_UPLOAD_URL"],
		UploadToken:    conf["ETLTV_UPLOAD_TOKEN"],
	}
}

// supervise runs the server and the ETLTV recorder, and never returns.
func supervise(args []string, conf map[string]string) {
	kids := newChildren()

	term := make(chan os.Signal, 4)
	signal.Notify(term, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGQUIT)

	stdio := &os.ProcAttr{Dir: gameBase, Env: os.Environ(), Files: []*os.File{os.Stdin, os.Stdout, os.Stderr}}

	if getenv("AUTORESTART", "true") == "true" {
		if interval := getenv("AUTORESTART_INTERVAL", "120"); interval != "0" {
			if pid, _, err := kids.start([]string{gameBase + "/autorestart", interval}, stdio); err != nil {
				fmt.Printf("WARNING: Failed to start autorestart daemon: %v\n", err)
			} else {
				fmt.Printf("Autorestart daemon started (PID %d)\n", pid)
			}
		}
	}

	masterPid, masterExit, err := kids.start(args, stdio)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start %s: %v\n", args[0], err)
		os.Exit(1)
	}

	stopTV := startETLTV(kids, conf, masterPid)

	for {
		select {
		case ws := <-masterExit:
			fmt.Printf("Server exited (code %d), stopping ETLTV\n", exitCode(ws))
			stopTV("quit")
			os.Exit(exitCode(ws))

		case sig := <-term:
			// Stop the recorder first so its demo is closed while the
			// server is still up, then pass the signal on.
			fmt.Printf("Received %v, stopping ETLTV before the server\n", sig)
			stopTV("shutdown")
			// On a tty, Ctrl-C and friends already reached the server, which
			// shares our process group; a second signal makes etlded abort
			// its shutdown.
			if sig == syscall.SIGTERM || !isTerminal(os.Stdin) {
				syscall.Kill(masterPid, sig.(syscall.Signal))
			}
		}
	}
}

// startETLTV starts the recorder, its control socket and the uploader, and
// returns a function that stops them all; later calls do nothing.
func startETLTV(kids *children, conf map[string]string, masterPid int) func(reason string) {
	cfg := etltvConfig(conf)
	logf := func(format string, args ...any) {
		fmt.Printf("[etltv] "+format+"\n", args...)
	}

	start := func(argv []string, out *os.File) (etltv.Process, error) {
		devnull, err := os.Open(os.DevNull)
		if err != nil {
			return nil, err
		}
		defer devnull.Close()
		attr := &os.ProcAttr{
			Dir:   gameBase,
			Env:   os.Environ(),
			Files: []*os.File{devnull, out, out},
			// Its own process group, so a tty Ctrl-C meant for the server
			// does not also hit the slave; we stop it ourselves, in order.
			Sys: &syscall.SysProcAttr{Setpgid: true},
		}
		pid, exit, err := kids.start(argv, attr)
		if err != nil {
			return nil, err
		}
		if err := lowerPriority(pid, masterPid, slaveNice); err != nil {
			fmt.Printf("WARNING: Could not lower the ETLTV slave's priority: %v\n", err)
		}
		p := &slaveProc{pid: pid, done: make(chan struct{})}
		go func() {
			<-exit
			close(p.done)
		}()
		return p, nil
	}
	masterAddr := "127.0.0.1:" + conf["MAP_PORT"]
	status := func() (etlproto.Status, error) {
		return etlproto.GetStatus(masterAddr, time.Second)
	}

	ctx, cancel := context.WithCancel(context.Background())
	uploader := etltv.NewUploader(cfg, logf)
	finished := func() {}
	if uploader != nil {
		finished = uploader.Notify
		go uploader.Run(ctx)
	} else {
		logf("uploads off, ETLTV_UPLOAD_URL is not set; demos stay in %s", cfg.DemoDir)
	}

	tv := etltv.NewManager(cfg, start, status, logf, finished)
	go tv.Run(ctx)

	ln, err := etltv.Listen(etltv.DefaultSocket, tv.Handle)
	if err != nil {
		fmt.Printf("WARNING: ETLTV control socket unavailable: %v\n", err)
	}

	var once sync.Once
	return func(reason string) {
		once.Do(func() {
			tv.Shutdown(reason)
			cancel()
			if ln != nil {
				ln.Close()
			}
		})
	}
}
