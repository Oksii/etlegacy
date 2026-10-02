package etltv

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var unsafeNameChars = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func sanitize(s string) string {
	s = unsafeNameChars.ReplaceAllString(s, "-")
	s = strings.Trim(s, ".-")
	if len(s) > 64 {
		s = strings.Trim(s[:64], ".-")
	}
	return s
}

// demoName builds "[tag_]YYYY-MM-DD_HHMMSS_map<ext>".
func demoName(tag, mapName, ext string, started time.Time) string {
	m := sanitize(mapName)
	if m == "" {
		m = "unknown"
	}
	name := started.Format("2006-01-02_150405") + "_" + m
	if t := sanitize(tag); t != "" {
		name = t + "_" + name
	}
	return name + ext
}

func uniquePath(dir, name string) string {
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for i := 1; ; i++ {
		candidate := name
		if i > 1 {
			candidate = base + "-" + strconv.Itoa(i) + ext
		}
		p := filepath.Join(dir, candidate)
		if _, err := os.Lstat(p); errors.Is(err, os.ErrNotExist) {
			return p
		}
	}
}

func moveFile(src, dst string) error {
	err := os.Rename(src, dst)
	if err == nil || !errors.Is(err, syscall.EXDEV) {
		return err
	}

	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	tmp := dst + ".tmp"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, dst); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Remove(src)
}
