package etltv

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeDemo(t *testing.T, dir, name string, meta Meta) string {
	t.Helper()
	os.MkdirAll(dir, 0755)
	path := filepath.Join(dir, name)
	data, _ := json.Marshal(meta)
	os.WriteFile(path+".json", data, 0644)
	if err := os.WriteFile(path, []byte("tvdemo bytes"), 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestUploadSendsFinishedDemos(t *testing.T) {
	type received struct {
		auth   string
		fields map[string]string
		file   string
	}
	got := make(chan received, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		rec := received{auth: r.Header.Get("Authorization"), fields: map[string]string{}}
		for k, v := range r.MultipartForm.Value {
			rec.fields[k] = v[0]
		}
		f, _, err := r.FormFile("file")
		if err == nil {
			b, _ := io.ReadAll(f)
			rec.file = string(b)
		}
		got <- rec
	}))
	defer srv.Close()

	dir := t.TempDir()
	started := time.Date(2026, 10, 2, 21, 30, 0, 0, time.UTC)
	path := writeDemo(t, dir, "cup_2026-10-02_213000_supply.tv_84", Meta{
		Map: "supply", Tag: "cup", StartedAt: started, EndedAt: started.Add(time.Hour),
		EndReason: reasonMapChange, ServerPort: "27960", Hostname: "Test",
	})
	// Companions and markers are never uploaded themselves.
	os.WriteFile(filepath.Join(dir, "other.tv_84.tmp"), nil, 0644)

	u := NewUploader(Config{UploadURL: srv.URL, UploadToken: "secret", DemoDir: dir}, t.Logf)
	if err := u.drain(context.Background()); err != nil {
		t.Fatalf("drain: %v", err)
	}

	rec := <-got
	if rec.auth != "Bearer secret" {
		t.Errorf("Authorization = %q", rec.auth)
	}
	want := map[string]string{
		"filename": "cup_2026-10-02_213000_supply.tv_84", "map": "supply", "tag": "cup",
		"end_reason": "map_change", "started_at": "2026-10-02T21:30:00Z", "server_port": "27960",
	}
	for k, v := range want {
		if rec.fields[k] != v {
			t.Errorf("field %s = %q, want %q", k, rec.fields[k], v)
		}
	}
	if rec.file != "tvdemo bytes" {
		t.Errorf("file = %q", rec.file)
	}
	if !fileExists(path + ".uploaded") {
		t.Error("no .uploaded marker after a 2xx")
	}
	select {
	case extra := <-got:
		t.Errorf("unexpected second upload: %+v", extra)
	default:
	}

	// Already uploaded: a second pass sends nothing.
	if err := u.drain(context.Background()); err != nil {
		t.Fatalf("second drain: %v", err)
	}
	select {
	case <-got:
		t.Error("uploaded twice")
	default:
	}
}

func TestUploadFailureKeepsDemoPending(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "storage down", http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	dir := t.TempDir()
	path := writeDemo(t, dir, "2026-10-02_213000_supply.tv_84", Meta{})

	u := NewUploader(Config{UploadURL: srv.URL, DemoDir: dir}, t.Logf)
	if err := u.drain(context.Background()); err == nil {
		t.Fatal("expected an error for a 503")
	}
	if fileExists(path + ".uploaded") {
		t.Error("marker written for a failed upload")
	}
	if p := pendingDemos(dir); len(p) != 1 {
		t.Errorf("pending = %v, want the demo still pending", p)
	}
}

func TestNoUploaderWithoutURL(t *testing.T) {
	if u := NewUploader(Config{}, t.Logf); u != nil {
		t.Error("uploader created without ETLTV_UPLOAD_URL")
	}
}
