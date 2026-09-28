package main

import "testing"

func TestResolveHostname(t *testing.T) {
	tests := []struct {
		name           string
		serverHostname string
		hostname       string
		kernelHostname string
		want           string
	}{
		{"SERVER_HOSTNAME wins over runtime HOSTNAME", "Pappa", "etlegacy", "etlegacy", "Pappa"},
		{"user HOSTNAME overrides container ID", "", "My Server", "3f2a9c1b7e44", "My Server"},
		{"default container ID ignored", "", "3f2a9c1b7e44", "3f2a9c1b7e44", "ETL Docker Server"},
		{"compose hostname kept", "", "myserver", "myserver", "myserver"},
		{"hex HOSTNAME set explicitly kept", "", "3f2a9c1b7e44", "other", "3f2a9c1b7e44"},
		{"nothing set", "", "", "", "ETL Docker Server"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := resolveHostname(tt.serverHostname, tt.hostname, tt.kernelHostname); got != tt.want {
				t.Errorf("resolveHostname(%q, %q, %q) = %q, want %q",
					tt.serverHostname, tt.hostname, tt.kernelHostname, got, tt.want)
			}
		})
	}
}
