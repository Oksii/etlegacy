package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
)

const (
	gameBase         = "/legacy/server"
	settingsBase     = gameBase + "/settings"
	etmainDir        = gameBase + "/etmain"
	legacyDir        = gameBase + "/legacy"
	homepath         = "/legacy/homepath"
	settingsManifest = settingsBase + "/.managed-settings-files"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func parseBoolValue(v string, def bool) bool {
	s := strings.TrimSpace(strings.ToLower(v))
	switch s {
	case "":
		return def
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return def
	}
}

func loadConf() map[string]string {
	conf := map[string]string{
		"HOSTNAME":                      getenv("HOSTNAME", "ETL Docker Server"),
		"MAP_PORT":                      getenv("MAP_PORT", "27960"),
		"MAP_IP":                        getenv("MAP_IP", ""),
		"REDIRECTURL":                   getenv("REDIRECTURL", "https://dl.etl.lol/maps/et"),
		"MAXCLIENTS":                    getenv("MAXCLIENTS", "24"),
		"STARTMAP":                      getenv("STARTMAP", "radar"),
		"TIMEOUTLIMIT":                  getenv("TIMEOUTLIMIT", "1"),
		"SERVERCONF":                    getenv("SERVERCONF", "legacy6"),
		"SVTRACKER":                     getenv("SVTRACKER", ""),
		"ADVERT":                        getenv("ADVERT", "0"),
		"MOTD":                          getenv("CONF_MOTD", ""),
		"PASSWORD":                      getenv("PASSWORD", ""),
		"RCONPASSWORD":                  getenv("RCONPASSWORD", ""),
		"REFPASSWORD":                   getenv("REFPASSWORD", ""),
		"SCPASSWORD":                    getenv("SCPASSWORD", ""),
		"SVAUTODEMO":                    getenv("SVAUTODEMO", "0"),
		"ETLTVMAXSLAVES":                getenv("SVETLTVMAXSLAVES", "2"),
		"ETLTVPASSWORD":                 getenv("SVETLTVPASSWORD", "3tltv"),
		"SETTINGSURL":                   getenv("SETTINGSURL", "https://github.com/Oksii/legacy-configs.git"),
		"SETTINGSPAT":                   getenv("SETTINGSPAT", ""),
		"SETTINGSBRANCH":                getenv("SETTINGSBRANCH", "main"),
		"ETLDED_REPO":                   getenv("ETLDED_REPO", ""),
		"ETLDED_TAG":                    getenv("ETLDED_TAG", "latest"),
		"ETLDED_URL":                    getenv("ETLDED_URL", ""),
		"STATS_SUBMIT":                  getenv("STATS_SUBMIT", "false"),
		"STATS_API_TOKEN":               getenv("STATS_API_TOKEN", "GameStatsWebLuaToken"),
		"STATS_API_PATH":                getenv("STATS_API_PATH", ""),
		"STATS_API_URL_SUBMIT":          getenv("STATS_API_URL_SUBMIT", "https://api.etl.lol/api/v2/stats/etl/matches/stats/submit"),
		"STATS_API_URL_MATCHID":         getenv("STATS_API_URL_MATCHID", "https://api.etl.lol/api/v2/stats/etl/match-manager"),
		"STATS_API_URL_VERSION":         getenv("STATS_API_URL_VERSION", "https://api.etl.lol/api/v2/stats/etl/matches/stats/version"),
		"STATS_API_LOG":                 getenv("STATS_API_LOG", "false"),
		"STATS_API_LOG_LEVEL":           getenv("STATS_API_LOG_LEVEL", "info"),
		"STATS_API_GAMELOG":             getenv("STATS_API_GAMELOG", "true"),
		"STATS_API_OBJSTATS":            getenv("STATS_API_OBJSTATS", "true"),
		"STATS_API_SHOVESTATS":          getenv("STATS_API_SHOVESTATS", "true"),
		"STATS_API_MOVEMENTSTATS":       getenv("STATS_API_MOVEMENTSTATS", "true"),
		"STATS_API_STANCESTATS":         getenv("STATS_API_STANCESTATS", "true"),
		"STATS_API_VEHICLESTATS":        getenv("STATS_API_VEHICLESTATS", "true"),
		"STATS_API_VEHICLE_TELEMETRY":   getenv("STATS_API_VEHICLE_TELEMETRY", "true"),
		"STATS_API_VEHICLE_DAMAGE":      getenv("STATS_API_VEHICLE_DAMAGE", "true"),
		"STATS_API_WEAPON_FIRE":         getenv("STATS_API_WEAPON_FIRE", "spam,utility,support,-pliers"),
		"STATS_API_DUMPJSON":            getenv("STATS_API_DUMPJSON", "false"),
		"STATS_API_VERSION_CHECK":       getenv("STATS_API_VERSION_CHECK", "true"),
		"STATS_GATHER_FEATURES":         getenv("STATS_GATHER_FEATURES", "false"),
		"CF_DEFAULT_CLASS":              getenv("CF_DEFAULT_CLASS", "true"),
		"CF_GUID_BLOCKER":               getenv("CF_GUID_BLOCKER", "true"),
		"CF_TECH_PAUSE":                 getenv("CF_TECH_PAUSE", "true"),
		"CF_TECH_PAUSE_LENGTH":          getenv("CF_TECH_PAUSE_LENGTH", "600"),
		"CF_TECH_PAUSE_COUNT":           getenv("CF_TECH_PAUSE_COUNT", "1"),
		"CF_PAUSE_LENGTH":               getenv("CF_PAUSE_LENGTH", "120"),
		"CF_TEAM_LOCK":                  getenv("CF_TEAM_LOCK", "true"),
		"CF_COMMAND_LOGGING":            getenv("CF_COMMAND_LOGGING", "true"),
		"CF_COMMAND_LOG_VOTES":          getenv("CF_COMMAND_LOG_VOTES", "true"),
		"CF_COMMAND_LOG_REF":            getenv("CF_COMMAND_LOG_REF", "true"),
		"CF_SPAWN_INVUL_SECONDS":        getenv("CF_SPAWN_INVUL_SECONDS", "1"),
		"CF_BAN_REASON":                 getenv("CF_BAN_REASON", "Banned."),
		"CF_LOG_FILEPATH":               getenv("CF_LOG_FILEPATH", ""),
		"CF_GUID_BLOCKER_TARGETS":       getenv("CF_GUID_BLOCKER_TARGETS", "F2ECF20F3ED6A5A93F2C49EF239F4488"),
		"CF_BANNED_GUIDS":               getenv("CF_BANNED_GUIDS", ""),
		"CF_BANNED_IPS":                 getenv("CF_BANNED_IPS", ""),
		"CF_VOTE_BANNED_GUIDS":          getenv("CF_VOTE_BANNED_GUIDS", ""),
		"STATS_AUTO_CONFIG_2":           getenv("STATS_AUTO_CONFIG_2", "legacy1"),
		"STATS_AUTO_CONFIG_4":           getenv("STATS_AUTO_CONFIG_4", "legacy3"),
		"STATS_AUTO_CONFIG_6":           getenv("STATS_AUTO_CONFIG_6", "legacy3"),
		"STATS_AUTO_CONFIG_10":          getenv("STATS_AUTO_CONFIG_10", "legacy5"),
		"STATS_AUTO_CONFIG_12":          getenv("STATS_AUTO_CONFIG_12", "legacy6"),
		"STATS_AUTO_SCORES":             getenv("STATS_AUTO_SCORES", "false"),
		"STATS_AUTO_START_WAIT_INITIAL": getenv("STATS_AUTO_START_WAIT_INITIAL", "420"),
		"STATS_AUTO_START_WAIT":         getenv("STATS_AUTO_START_WAIT", "180"),
		"STATS_AUTO_START_MODE":         getenv("STATS_AUTO_START_MODE", "simple"),
		"STATS_AUTO_START_CONNECT_WAIT": getenv("STATS_AUTO_START_CONNECT_WAIT", "180"),
		"STATS_AUTO_START_READY_WAIT":   getenv("STATS_AUTO_START_READY_WAIT", "120"),
		"ASSETS":                        getenv("ASSETS", "false"),
		"ASSETS_URL":                    getenv("ASSETS_URL", ""),
		"OMNIBOT":                       getenv("OMNIBOT", "0"),
		"MAPS_AUTO":                     getenv("MAPS_AUTO", "true"),
		"MAPS_FORCE_COPY":               getenv("MAPS_FORCE_COPY", "false"),
	}

	if conf["STATS_SUBMIT"] == "true" && conf["SETTINGSBRANCH"] == "main" {
		conf["SETTINGSBRANCH"] = "etl-stats-api"
	}

	// Mirror stats.lua: STATS_GATHER_FEATURES=true enables all individual gather flags,
	// but only when the user has not explicitly set an individual flag themselves.
	if conf["STATS_GATHER_FEATURES"] == "true" {
		for _, k := range []string{
			"STATS_AUTO_RENAME", "STATS_AUTO_SORT", "STATS_AUTO_START",
			"STATS_AUTO_MAP", "STATS_AUTO_CONFIG", "STATS_AUTO_SCORES",
		} {
			if os.Getenv(k) == "" {
				conf[k] = "true"
			}
		}
	}

	// Overlay any CONF_* environment variables, allowing users to substitute
	// arbitrary %CONF_FOO% placeholders in etl_server.cfg by setting CONF_FOO=value.
	for _, env := range os.Environ() {
		if !strings.HasPrefix(env, "CONF_") {
			continue
		}
		parts := strings.SplitN(env, "=", 2)
		key := strings.TrimPrefix(parts[0], "CONF_")
		if len(parts) == 2 {
			conf[key] = parts[1]
		}
	}

	// ADVERT: escalate to 2 (tracker) when SVTRACKER is set, unless user explicitly provided ADVERT.
	if conf["SVTRACKER"] != "" && os.Getenv("ADVERT") == "" {
		conf["ADVERT"] = "2"
	}

	return conf
}

func updateConfigs(conf map[string]string) (bool, error) {
	fmt.Println("Checking for configuration updates...")
	authURL := conf["SETTINGSURL"]
	if pat := conf["SETTINGSPAT"]; pat != "" {
		authURL = strings.Replace(authURL, "https://", "https://"+pat+"@", 1)
	}
	newSettings := settingsBase + ".new"
	if err := os.RemoveAll(newSettings); err != nil {
		return false, fmt.Errorf("remove previous staging dir %s: %w", newSettings, err)
	}
	cmd := exec.Command("git", "clone", "--depth", "1", "--single-branch",
		"--branch", conf["SETTINGSBRANCH"], authURL, newSettings)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return false, fmt.Errorf("git clone failed: %w", err)
	}

	revCmd := exec.Command("git", "-C", newSettings, "rev-parse", "--short", "HEAD")
	revOut, revErr := revCmd.Output()
	if revErr == nil {
		fmt.Printf("Settings source revision: %s\n", strings.TrimSpace(string(revOut)))
	} else {
		fmt.Printf("WARNING: Could not resolve settings source revision: %v\n", revErr)
	}

	if err := syncSettingsDir(newSettings, settingsBase); err != nil {
		return false, err
	}
	if err := os.RemoveAll(newSettings); err != nil {
		fmt.Printf("WARNING: Failed to remove staging settings dir %s: %v\n", newSettings, err)
	}
	return true, nil
}

func syncSettingsDir(srcDir, dstDir string) error {
	if err := os.MkdirAll(dstDir, 0755); err != nil {
		return fmt.Errorf("create destination settings dir %s: %w", dstDir, err)
	}

	for _, rel := range readManagedRelPaths(settingsManifest) {
		if rel == ".git" || strings.HasPrefix(rel, ".git/") {
			continue
		}
		if err := os.RemoveAll(filepath.Join(dstDir, rel)); err != nil {
			return fmt.Errorf("cleanup managed settings path %s: %w", rel, err)
		}
	}

	var managed []string
	err := filepath.WalkDir(srcDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(srcDir, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		if rel == ".git" || strings.HasPrefix(rel, ".git/") {
			return nil
		}
		managed = append(managed, rel)
		dstPath := filepath.Join(dstDir, rel)
		if d.IsDir() {
			return os.MkdirAll(dstPath, 0755)
		}
		return copyFile(path, dstPath)
	})
	if err != nil {
		return err
	}
	writeManagedRelPaths(settingsManifest, managed)
	return nil
}

func clearDirContents(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	for _, entry := range entries {
		if err := os.RemoveAll(filepath.Join(dir, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func readManagedRelPaths(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		rel := strings.TrimSpace(line)
		if rel == "" || filepath.IsAbs(rel) {
			continue
		}
		clean := filepath.Clean(rel)
		if clean == "." || strings.HasPrefix(clean, "..") {
			continue
		}
		out = append(out, clean)
	}
	return out
}

func writeManagedRelPaths(path string, relPaths []string) {
	content := strings.Join(relPaths, "\n")
	if content != "" {
		content += "\n"
	}
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		fmt.Printf("WARNING: Failed to write settings manifest %s: %v\n", path, err)
	}
}

func dlProgressBar(done, total int) string {
	const width = 20
	filled := 0
	if total > 0 {
		filled = done * width / total
	}
	return "[" + strings.Repeat("█", filled) + strings.Repeat("░", width-filled) + "]"
}

func dlFmtBytes(n int64) string {
	switch {
	case n >= 1024*1024:
		return fmt.Sprintf("%.1f MB", float64(n)/1024/1024)
	case n >= 1024:
		return fmt.Sprintf("%.1f KB", float64(n)/1024)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

func scanLocalMapVolume() []string {
	entries, err := os.ReadDir("/maps")
	if err != nil {
		fmt.Printf("Maps: /maps volume not readable: %v\n", err)
		return nil
	}
	var maps []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".pk3") {
			maps = append(maps, strings.TrimSuffix(name, ".pk3"))
		}
	}
	return maps
}

func downloadMaps(conf map[string]string) {
	seen := map[string]bool{}
	var candidates []string
	add := func(name string) {
		if name != "" && !seen[name] {
			seen[name] = true
			candidates = append(candidates, name)
		}
	}
	for _, m := range strings.Split(os.Getenv("MAPS"), ":") {
		add(strings.TrimSpace(m))
	}
	if conf["MAPS_AUTO"] == "true" {
		for _, m := range scanLocalMapVolume() {
			add(m)
		}
	}
	if len(candidates) == 0 {
		fmt.Println("Maps: no candidates (MAPS env empty, MAPS_AUTO found nothing)")
		return
	}
	fmt.Printf("Maps: %d candidate(s) to process\n", len(candidates))

	forceCopy := conf["MAPS_FORCE_COPY"] == "true"
	var toDownload []string
	for _, m := range candidates {
		dest := filepath.Join(etmainDir, m+".pk3")
		if !forceCopy {
			if _, err := os.Stat(dest); err == nil {
				fmt.Printf("Map %s already in etmain, skipping\n", m)
				continue
			}
		}
		if _, err := os.Stat("/maps/" + m + ".pk3"); err == nil {
			fmt.Printf("Map %s is sourcable locally, copying into place\n", m)
			if err := copyFile("/maps/"+m+".pk3", dest); err != nil {
				fmt.Printf("WARNING: Failed to copy %s: %v\n", m, err)
			}
		} else {
			toDownload = append(toDownload, m)
		}
	}
	if len(toDownload) == 0 {
		return
	}
	total := len(toDownload)
	fmt.Printf("Downloading %d map(s) in parallel...\n", total)

	sem := make(chan struct{}, 30)
	var wg sync.WaitGroup
	var done, errCount, totalBytes int64

	for _, m := range toDownload {
		wg.Add(1)
		go func(mapName string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			dest := filepath.Join(etmainDir, mapName+".pk3")
			start := time.Now()

			fail := func(format string, args ...any) {
				n := int(atomic.AddInt64(&done, 1))
				atomic.AddInt64(&errCount, 1)
				fmt.Printf("[%d/%d] %s  WARNING: "+format+"\n",
					append([]any{n, total, dlProgressBar(n, total)}, args...)...)
			}

			resp, err := http.Get(conf["REDIRECTURL"] + "/etmain/" + mapName + ".pk3")
			if err != nil {
				fail("%s: %v", mapName, err)
				return
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				fail("%s: HTTP %d", mapName, resp.StatusCode)
				return
			}

			f, err := os.Create(dest)
			if err != nil {
				fail("%s: create failed: %v", mapName, err)
				return
			}

			written, err := io.Copy(f, resp.Body)
			f.Close()
			if err != nil {
				os.Remove(dest)
				fail("%s: write failed: %v", mapName, err)
				return
			}

			atomic.AddInt64(&totalBytes, written)
			n := int(atomic.AddInt64(&done, 1))
			fmt.Printf("[%d/%d] %s  %-30s  %s  (%.1fs)\n",
				n, total, dlProgressBar(n, total),
				mapName, dlFmtBytes(written), time.Since(start).Seconds())
		}(m)
	}
	wg.Wait()

	errs := atomic.LoadInt64(&errCount)
	if errs > 0 {
		fmt.Printf("Maps: %d/%d downloaded (%s total, %d failed)\n",
			int64(total)-errs, int64(total), dlFmtBytes(atomic.LoadInt64(&totalBytes)), errs)
	} else {
		fmt.Printf("Maps: all %d downloaded (%s total)\n", total, dlFmtBytes(atomic.LoadInt64(&totalBytes)))
	}
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

func copyGameAssets() {
	os.MkdirAll(etmainDir+"/mapscripts", 0755)
	os.MkdirAll(legacyDir+"/luascripts", 0755)

	for _, s := range mustGlob(etmainDir + "/mapscripts/*.script") {
		os.Remove(s)
	}
	for _, s := range mustGlob(settingsBase + "/mapscripts/*.script") {
		copyFile(s, etmainDir+"/mapscripts/"+filepath.Base(s))
	}

	if err := clearDirContents(legacyDir + "/luascripts"); err != nil {
		fmt.Printf("WARNING: Failed to clear luascripts directory: %v\n", err)
	}
	srcLua := settingsBase + "/luascripts"
	filepath.WalkDir(srcLua, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(srcLua, path)
		dst := filepath.Join(legacyDir+"/luascripts", rel)
		if d.IsDir() {
			return os.MkdirAll(dst, 0755)
		}
		return copyFile(path, dst)
	})

	for _, cm := range mustGlob(settingsBase + "/commandmaps/*.pk3") {
		name := filepath.Base(cm)
		if err := copyFile(cm, legacyDir+"/"+name); err != nil {
			fmt.Printf("WARNING: Failed to copy commandmap %s: %v\n", name, err)
		}
	}

	os.RemoveAll(etmainDir + "/configs")
	os.MkdirAll(etmainDir+"/configs", 0755)
	for _, c := range mustGlob(settingsBase + "/configs/*.config") {
		copyFile(c, etmainDir+"/configs/"+filepath.Base(c))
	}
}

func mustGlob(pattern string) []string {
	matches, _ := filepath.Glob(pattern)
	return matches
}

var remainingPlaceholderRe = regexp.MustCompile(`%CONF_[A-Z_]+%`)
var motdLineRe = regexp.MustCompile(`(?m)^set server_motd[0-9][^\n]*\n?`)

// ----------------------------------------------------------------------------
// Server binary updates
//
// Off unless ETLDED_REPO or ETLDED_URL is set, in which case the etlded binary
// baked into the image is replaced before the server starts. Lets a patched
// engine be rolled out by restarting the container rather than rebuilding it,
// the same way updateConfigs picks up settings changes.
// ----------------------------------------------------------------------------

// ghRelease is the subset of the GitHub releases API that we need.
type ghRelease struct {
	TagName     string    `json:"tag_name"`
	Draft       bool      `json:"draft"`
	PublishedAt time.Time `json:"published_at"`
	Assets      []ghAsset `json:"assets"`
}

// newestRelease returns the most recently published non-draft release whose tag
// starts with prefix; an empty prefix matches any tag.
//
// The releases endpoint takes no sort parameter and its default order is not
// contractual, so the choice is made here rather than by taking the first entry.
// Note that sorting has to use published_at: created_at is a git timestamp (the
// tagged commit or tag object), so tagging an older commit would sort a new
// release below older ones.
func newestRelease(list []ghRelease, prefix string) (ghRelease, bool) {
	var best ghRelease
	found := false
	for _, r := range list {
		if r.Draft || !strings.HasPrefix(r.TagName, prefix) {
			continue
		}
		if !found || r.PublishedAt.After(best.PublishedAt) {
			best, found = r, true
		}
	}
	return best, found
}

type ghAsset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
}

// pickAsset chooses the Linux asset matching one of tokens, most specific
// first. Split out from resolveReleaseAsset so the per-architecture choice can
// be tested without running on that architecture.
func pickAsset(assets []ghAsset, tokens []string) (ghAsset, bool) {
	for _, tok := range tokens {
		for _, a := range assets {
			n := strings.ToLower(a.Name)
			// Linux assets only: the same release carries Windows and macOS builds.
			if strings.Contains(n, "win") || strings.Contains(n, "osx") || strings.Contains(n, "mac") {
				continue
			}
			if strings.Contains(n, tok) {
				return a, true
			}
		}
	}
	return ghAsset{}, false
}

// archTokens lists the substrings a release asset may use to name this build's
// architecture, most specific first. runtime.GOARCH is the architecture the
// entrypoint itself was cross-compiled for, which is the image's architecture.
func archTokens() []string {
	switch runtime.GOARCH {
	case "amd64":
		return []string{"x86_64", "amd64"}
	case "arm64":
		return []string{"aarch64", "arm64"}
	case "386":
		return []string{"i386", "x86"}
	case "arm":
		return []string{"armv7", "armhf", "arm"}
	default:
		return []string{runtime.GOARCH}
	}
}

// resolveReleaseAsset finds the download URL of the asset matching this
// architecture in the given repo's release. An empty tag, or the literal
// "latest", resolves to the newest published release rather than naming a tag.
//
// This needs a repo that attaches binaries to its releases. etlegacy/etlegacy
// has tags but no GitHub releases, so it cannot be used as a source here.
func resolveReleaseAsset(repo, tag string) (assetURL, version string, err error) {
	// A tag of "latest" (or empty) means the newest published release, and a
	// trailing "*" means the newest release whose tag has that prefix, which is
	// how a fork publishing several feature branches tracks just one of them.
	// Both list releases, because /releases/latest hides pre-releases and test
	// builds usually are pre-releases.
	prefix, listing := "", true
	switch {
	case tag == "" || tag == "latest":
	case strings.HasSuffix(tag, "*"):
		prefix = strings.TrimSuffix(tag, "*")
	default:
		listing = false
	}

	api := "https://api.github.com/repos/" + repo + "/releases?per_page=100"
	if !listing {
		api = "https://api.github.com/repos/" + repo + "/releases/tags/" + tag
	}

	req, err := http.NewRequest(http.MethodGet, api, nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("%s returned %s", api, resp.Status)
	}

	var rel ghRelease
	if listing {
		var list []ghRelease
		if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
			return "", "", fmt.Errorf("decode releases: %w", err)
		}
		var found bool
		if rel, found = newestRelease(list, prefix); !found {
			if prefix != "" {
				return "", "", fmt.Errorf("%s has no published release with tag prefix %q", repo, prefix)
			}
			return "", "", fmt.Errorf("%s has no published releases", repo)
		}
	} else if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return "", "", fmt.Errorf("decode release: %w", err)
	}

	if a, ok := pickAsset(rel.Assets, archTokens()); ok {
		return a.URL, rel.TagName + "/" + a.Name, nil
	}
	return "", "", fmt.Errorf("release %s has no asset for %s", rel.TagName, runtime.GOARCH)
}

// extractBinary returns the etlded binary from a downloaded asset, unwrapping
// it if the asset is a zip.
func extractBinary(data []byte, name string) ([]byte, error) {
	if !bytes.HasPrefix(data, []byte("PK\x03\x04")) {
		return data, nil // a bare binary
	}

	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("open zip %s: %w", name, err)
	}
	for _, f := range zr.File {
		if f.FileInfo().IsDir() || !strings.HasPrefix(filepath.Base(f.Name), "etlded") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, fmt.Errorf("read %s from %s: %w", f.Name, name, err)
		}
		defer rc.Close()
		return io.ReadAll(rc)
	}
	return nil, fmt.Errorf("no etlded binary inside %s", name)
}

// updateServerBinary replaces gameBase/etlded before the server is started.
// Any failure leaves the existing binary in place: a bad download must not stop
// the server from coming up.
func updateServerBinary(conf map[string]string) {
	assetURL, version := conf["ETLDED_URL"], conf["ETLDED_URL"]
	if assetURL == "" {
		if conf["ETLDED_REPO"] == "" {
			return // disabled, use the binary shipped in the image
		}
		var err error
		assetURL, version, err = resolveReleaseAsset(conf["ETLDED_REPO"], conf["ETLDED_TAG"])
		if err != nil {
			fmt.Printf("WARNING: Server binary update skipped: %v\n", err)
			return
		}
	}

	etlded := gameBase + "/etlded"
	marker := gameBase + "/.etlded-version"
	if b, err := os.ReadFile(marker); err == nil && strings.TrimSpace(string(b)) == version {
		fmt.Printf("Server binary already at %s\n", version)
		return
	}

	fmt.Printf("Updating server binary (%s) from %s\n", runtime.GOARCH, assetURL)
	resp, err := (&http.Client{Timeout: 5 * time.Minute}).Get(assetURL)
	if err != nil {
		fmt.Printf("WARNING: Server binary download failed: %v\n", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Printf("WARNING: Server binary download failed: %s returned %s\n", assetURL, resp.Status)
		return
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Printf("WARNING: Server binary download failed: %v\n", err)
		return
	}

	bin, err := extractBinary(data, filepath.Base(assetURL))
	if err != nil {
		fmt.Printf("WARNING: Server binary update skipped: %v\n", err)
		return
	}
	if len(bin) == 0 || !bytes.HasPrefix(bin, []byte("\x7fELF")) {
		fmt.Printf("WARNING: Server binary update skipped: %s is not an ELF binary\n", assetURL)
		return
	}

	// Keep the image's own binary once, so ETLDED_REPO= reverts on next restart.
	if _, err := os.Stat(etlded + ".orig"); errors.Is(err, os.ErrNotExist) {
		if err := copyFile(etlded, etlded+".orig"); err != nil {
			fmt.Printf("WARNING: Could not back up original binary: %v\n", err)
		}
	}

	// Write beside the target and rename, so a partial write is never executed.
	tmp := etlded + ".new"
	if err := os.WriteFile(tmp, bin, 0755); err != nil {
		fmt.Printf("WARNING: Server binary update failed: %v\n", err)
		return
	}
	if err := os.Rename(tmp, etlded); err != nil {
		fmt.Printf("WARNING: Server binary update failed: %v\n", err)
		os.Remove(tmp)
		return
	}
	if err := os.WriteFile(marker, []byte(version), 0644); err != nil {
		fmt.Printf("WARNING: Could not record installed binary version: %v\n", err)
	}
	fmt.Printf("Server binary updated to %s\n", version)
}

func updateServerConfig(conf map[string]string) {
	cfgPath := etmainDir + "/etl_server.cfg"
	if err := copyFile(settingsBase+"/etl_server.cfg", cfgPath); err != nil {
		fmt.Printf("WARNING: Failed to copy etl_server.cfg: %v\n", err)
		return
	}

	content, err := os.ReadFile(cfgPath)
	if err != nil {
		fmt.Printf("WARNING: Failed to read etl_server.cfg: %v\n", err)
		return
	}
	s := string(content)

	for key, value := range conf {
		s = strings.ReplaceAll(s, "%CONF_"+key+"%", value)
	}
	s = remainingPlaceholderRe.ReplaceAllString(s, "")

	if motd := conf["MOTD"]; motd != "" {
		s = motdLineRe.ReplaceAllString(s, "")
		parts := strings.Split(motd, `\n`)
		var block strings.Builder
		for i := 0; i < 6; i++ {
			text := ""
			if i < len(parts) {
				text = parts[i]
			}
			fmt.Fprintf(&block, "set server_motd%d          \"%s\"\n", i, text)
		}
		lines := strings.Split(s, "\n")
		result := make([]string, 0, len(lines)+7)
		for _, line := range lines {
			result = append(result, line)
			if strings.HasPrefix(strings.TrimSpace(line), "set sv_hostname") {
				result = append(result, block.String())
			}
		}
		s = strings.Join(result, "\n")
	}

	os.WriteFile(cfgPath, []byte(s), 0644)

	if extra, err := os.ReadFile(gameBase + "/extra.cfg"); err == nil {
		if f, err := os.OpenFile(cfgPath, os.O_APPEND|os.O_WRONLY, 0644); err == nil {
			f.Write(extra)
			f.Close()
		}
	}
}

func handleExtraContent(conf map[string]string) {
	if conf["ASSETS"] != "true" {
		return
	}
	fmt.Println("Downloading assets...")
	resp, err := http.Get(conf["ASSETS_URL"])
	if err != nil {
		fmt.Printf("WARNING: Failed to download assets: %v\n", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Printf("WARNING: Failed to download assets: HTTP %d\n", resp.StatusCode)
		return
	}
	dest := filepath.Join(legacyDir, filepath.Base(conf["ASSETS_URL"]))
	if f, err := os.Create(dest); err == nil {
		io.Copy(f, resp.Body)
		f.Close()
	}
}

func resolvePublicIP() string {
	if ip := os.Getenv("MAP_IP"); ip != "" {
		return ip
	}
	client := &http.Client{Timeout: 3 * time.Second}
	for i := 0; i < 3; i++ {
		resp, err := client.Get("https://api.ipify.org")
		if err != nil {
			continue
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if ip := strings.TrimSpace(string(b)); ip != "" {
			return ip
		}
	}
	fmt.Println("WARNING: Could not resolve public IP, MAP_IP will not be set")
	return ""
}

func parseCLIArgs() []string {
	raw := os.Getenv("ADDITIONAL_CLI_ARGS")
	if raw == "" {
		return nil
	}
	runes := []rune(raw)
	var args []string
	var cur strings.Builder
	inSingle, inDouble := false, false
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		switch {
		case inSingle:
			if c == '\'' {
				inSingle = false
			} else {
				cur.WriteRune(c)
			}
		case inDouble:
			if c == '"' {
				inDouble = false
			} else if c == '\\' && i+1 < len(runes) {
				i++
				cur.WriteRune(runes[i])
			} else {
				cur.WriteRune(c)
			}
		case c == '\'':
			inSingle = true
		case c == '"':
			inDouble = true
		case unicode.IsSpace(c):
			if cur.Len() > 0 {
				args = append(args, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteRune(c)
		}
	}
	if cur.Len() > 0 {
		args = append(args, cur.String())
	}
	return args
}

func main() {
	if ip := resolvePublicIP(); ip != "" {
		os.Setenv("MAP_IP", ip)
		fmt.Printf("Public IP: %s\n", ip)
	}

	conf := loadConf()

	// Inject conf defaults into the process environment so that values not
	// explicitly set by the user are visible to Lua via os.getenv().
	for k, v := range conf {
		if os.Getenv(k) == "" {
			os.Setenv(k, v)
		}
	}

	autoUpdate := parseBoolValue(os.Getenv("AUTO_UPDATE"), true)
	fmt.Printf("Settings source URL: %s\n", conf["SETTINGSURL"])
	fmt.Printf("Settings branch: %s\n", conf["SETTINGSBRANCH"])
	fmt.Printf("AUTO_UPDATE resolved: %t\n", autoUpdate)

	if autoUpdate {
		updated, err := updateConfigs(conf)
		if err != nil {
			fmt.Printf("WARNING: Settings update failed: %v. Using last known settings.\n", err)
		} else if updated {
			fmt.Println("Settings update applied.")
		}
	} else {
		fmt.Println("AUTO_UPDATE disabled; using existing settings.")
	}
	downloadMaps(conf)
	copyGameAssets()
	updateServerConfig(conf)
	handleExtraContent(conf)
	updateServerBinary(conf)

	needpass := "0"
	if conf["PASSWORD"] != "" {
		needpass = "1"
	}

	etlded := gameBase + "/etlded"
	args := []string{
		etlded,
		"+set", "sv_maxclients", conf["MAXCLIENTS"],
		"+set", "net_port", conf["MAP_PORT"],
		"+set", "g_needpass", needpass,
		"+set", "fs_basepath", gameBase,
		"+set", "fs_homepath", homepath,
		"+set", "sv_tracker", conf["SVTRACKER"],
		"+set", "omnibot_enable", conf["OMNIBOT"],
		"+exec", "etl_server.cfg",
		"+map", conf["STARTMAP"],
	}
	args = append(args, parseCLIArgs()...)
	args = append(args, os.Args[1:]...)

	if getenv("AUTORESTART", "true") == "true" {
		if interval := getenv("AUTORESTART_INTERVAL", "120"); interval != "0" {
			cmd := exec.Command(gameBase+"/autorestart", interval)
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			if err := cmd.Start(); err != nil {
				fmt.Printf("WARNING: Failed to start autorestart daemon: %v\n", err)
			} else {
				fmt.Printf("Autorestart daemon started (PID %d)\n", cmd.Process.Pid)
			}
		}
	}

	if err := syscall.Exec(etlded, args, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to exec %s: %v\n", etlded, err)
		os.Exit(1)
	}
}
