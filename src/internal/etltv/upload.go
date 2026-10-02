package etltv

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Uploader POSTs finished demos to UploadURL. It only ever sees complete
// files: demos appear in DemoDir by rename once the slave has closed them.
// A file counts as done once <demo>.uploaded exists, which is written only
// after a 2xx response, so anything interrupted by a restart is retried on the
// next boot.
type Uploader struct {
	url, token string
	dir        string
	client     *http.Client
	logf       func(format string, args ...any)
	notify     chan struct{}
}

// NewUploader returns nil when no upload URL is configured.
func NewUploader(cfg Config, logf func(string, ...any)) *Uploader {
	if cfg.UploadURL == "" {
		return nil
	}
	return &Uploader{
		url:    cfg.UploadURL,
		token:  cfg.UploadToken,
		dir:    cfg.DemoDir,
		client: &http.Client{Timeout: 30 * time.Minute},
		logf:   logf,
		notify: make(chan struct{}, 1),
	}
}

// Notify wakes the uploader after a demo has been finished.
func (u *Uploader) Notify() {
	select {
	case u.notify <- struct{}{}:
	default:
	}
}

// Run uploads pending demos until ctx is done.
func (u *Uploader) Run(ctx context.Context) {
	failures := 0
	for {
		wait := 10 * time.Minute // periodic rescan
		if err := u.drain(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			failures++
			wait = retryDelay(failures)
			u.logf("upload failed, retrying in %s: %v", wait, err)
		} else {
			failures = 0
		}

		select {
		case <-ctx.Done():
			return
		case <-u.notify:
		case <-time.After(wait):
		}
	}
}

func retryDelay(failures int) time.Duration {
	d := 30 * time.Second
	for i := 1; i < failures && d < 10*time.Minute; i++ {
		d *= 2
	}
	if d > 10*time.Minute {
		d = 10 * time.Minute
	}
	return d
}

// drain uploads every pending demo, oldest name first, and stops at the first
// failure so the backoff applies.
func (u *Uploader) drain(ctx context.Context) error {
	for _, path := range pendingDemos(u.dir) {
		if err := u.upload(ctx, path); err != nil {
			return fmt.Errorf("%s: %w", filepath.Base(path), err)
		}
		marker := fmt.Sprintf("uploaded %s to %s\n", time.Now().UTC().Format(time.RFC3339), u.url)
		if err := os.WriteFile(path+".uploaded", []byte(marker), 0644); err != nil {
			return fmt.Errorf("%s: write marker: %w", filepath.Base(path), err)
		}
		u.logf("uploaded %s", filepath.Base(path))
	}
	return nil
}

// pendingDemos lists finished demos in dir that have no .uploaded marker.
func pendingDemos(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !isDemoFile(name) {
			continue
		}
		path := filepath.Join(dir, name)
		if fileExists(path + ".uploaded") {
			continue
		}
		out = append(out, path)
	}
	sort.Strings(out)
	return out
}

// isDemoFile matches "<name>.tv_<protocol>", not its .json/.uploaded/.tmp
// companions.
func isDemoFile(name string) bool {
	return strings.HasPrefix(filepath.Ext(name), ".tv_")
}

// upload streams the demo as multipart/form-data, so even a long match is
// never held in memory.
func (u *Uploader) upload(ctx context.Context, path string) error {
	meta := readMeta(path)

	pr, pw := io.Pipe()
	mw := multipart.NewWriter(pw)
	go func() {
		pw.CloseWithError(writeForm(mw, meta, path))
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.url, pr)
	if err != nil {
		pr.Close()
		return err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if u.token != "" {
		req.Header.Set("Authorization", "Bearer "+u.token)
	}

	resp, err := u.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	return nil
}

func writeForm(mw *multipart.Writer, meta Meta, path string) error {
	fields := [][2]string{
		{"filename", meta.Filename},
		{"map", meta.Map},
		{"tag", meta.Tag},
		{"started_at", formatTime(meta.StartedAt)},
		{"ended_at", formatTime(meta.EndedAt)},
		{"end_reason", meta.EndReason},
		{"server_ip", meta.ServerIP},
		{"server_port", meta.ServerPort},
		{"hostname", meta.Hostname},
	}
	for _, f := range fields {
		if err := mw.WriteField(f[0], f[1]); err != nil {
			return err
		}
	}

	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	part, err := mw.CreateFormFile("file", meta.Filename)
	if err != nil {
		return err
	}
	if _, err := io.Copy(part, f); err != nil {
		return err
	}
	return mw.Close()
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.Format(time.RFC3339)
}

// readMeta loads <demo>.json, falling back to just the file name if it is
// missing or unreadable.
func readMeta(path string) Meta {
	meta := Meta{Filename: filepath.Base(path)}
	if data, err := os.ReadFile(path + ".json"); err == nil {
		json.Unmarshal(data, &meta)
	}
	meta.Filename = filepath.Base(path)
	return meta
}
