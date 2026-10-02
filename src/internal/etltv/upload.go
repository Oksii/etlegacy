package etltv

import (
	"context"
	"encoding/json"
	"errors"
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

// Uploader POSTs finished demos to UploadURL.
type Uploader struct {
	url, token string
	dir        string
	client     *http.Client
	logf       func(format string, args ...any)
	notify     chan struct{}
}

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

func (u *Uploader) Notify() {
	select {
	case u.notify <- struct{}{}:
	default:
	}
}

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

func (u *Uploader) drain(ctx context.Context) error {
	for _, path := range pendingDemos(u.dir) {
		err := u.upload(ctx, path)
		var rej rejectedError
		if errors.As(err, &rej) {
			// Retrying would get the same answer and hold up every demo after it.
			os.WriteFile(path+".rejected", []byte(rej.Error()+"\n"), 0644)
			u.logf("%s rejected, not retrying: %v", filepath.Base(path), rej)
			continue
		}
		if err != nil {
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
		if fileExists(path+".uploaded") || fileExists(path+".rejected") {
			continue
		}
		out = append(out, path)
	}
	sort.Strings(out)
	return out
}

func isDemoFile(name string) bool {
	return strings.HasPrefix(filepath.Ext(name), ".tv_")
}

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
	if resp.StatusCode >= 200 && resp.StatusCode <= 299 {
		return nil
	}
	err = fmt.Errorf("%s: %s", resp.Status, strings.TrimSpace(string(body)))
	if refusesDemo(resp.StatusCode) {
		return rejectedError{err}
	}
	return err
}

type rejectedError struct{ error }

// Refusals of the demo itself. Anything else (auth, wrong URL, outages) is retried.
func refusesDemo(status int) bool {
	switch status {
	case http.StatusBadRequest, http.StatusRequestEntityTooLarge,
		http.StatusUnsupportedMediaType, http.StatusUnprocessableEntity:
		return true
	}
	return false
}

func writeForm(mw *multipart.Writer, meta demoMeta, path string) error {
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

func readMeta(path string) demoMeta {
	var meta demoMeta
	if data, err := os.ReadFile(path + ".json"); err == nil {
		json.Unmarshal(data, &meta)
	}
	meta.Filename = filepath.Base(path)
	return meta
}
