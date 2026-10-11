package etltv

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const routeTimeout = 2 * time.Second

func routeMatchID(cfg Config, logf func(string, ...any)) func() string {
	url := strings.TrimRight(cfg.MatchURL, "/") + "/" + cfg.ServerIP + "/" + cfg.MasterPort
	client := &http.Client{Timeout: routeTimeout}
	return func() string {
		id, err := fetchMatchID(client, url, cfg.MatchToken)
		if err != nil {
			logf("match id lookup failed, leaving the demo untagged: %v", err)
		}
		return id
	}
}

func fetchMatchID(client *http.Client, url, token string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return "", nil // no stats from this server, or the match ended
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s", resp.Status)
	}

	dec := json.NewDecoder(io.LimitReader(resp.Body, 1<<20))
	dec.UseNumber() // the route serves the id as a number
	var body struct {
		MatchID any `json:"match_id"`
	}
	if err := dec.Decode(&body); err != nil {
		return "", err
	}
	if body.MatchID == nil {
		return "", nil
	}
	id := fmt.Sprint(body.MatchID)
	if sanitize(id) != id {
		return "", fmt.Errorf("unusable match id %q", id)
	}
	return id, nil
}
