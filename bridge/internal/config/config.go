package config

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Config holds runtime configuration for the agy-bridge daemon.
type Config struct {
	ListenAddr       string   `json:"listenAddr"`
	HostName         string   `json:"hostName"`
	AntigravityDir   string   `json:"antigravityDir"`
	StateDBPath      string   `json:"stateDbPath"`
	AgentAPIBin      string   `json:"agentApiBin"`
	PublicEndpoints  []string `json:"publicEndpoints,omitempty"`
	SubscriptionTier string   `json:"subscriptionTier"`
	Gemini5hBudget   int64    `json:"gemini5hBudget"`
	Gemini7dBudget   int64    `json:"gemini7dBudget"`
	Claude5hBudget   int64    `json:"claude5hBudget"`
	Claude7dBudget   int64    `json:"claude7dBudget"`
	BootstrapToken   string   `json:"bootstrapToken,omitempty"`
}

// PairingPayload is encoded into the terminal QR code for one-scan pairing.
type PairingPayload struct {
	Version   int      `json:"v"`
	HostName  string   `json:"hostName"`
	Endpoints []string `json:"endpoints"`
	Token     string   `json:"token"`
}

// DefaultConfig returns sensible macOS defaults for Antigravity.
func DefaultConfig() (*Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home dir: %w", err)
	}
	hostName, _ := os.Hostname()
	hostName = strings.TrimSuffix(hostName, ".local")
	if hostName == "" {
		hostName = "AntigravityHost"
	}

	agyDir := filepath.Join(home, ".gemini", "antigravity")
	cfgDir := filepath.Join(home, ".config", "antigravity-mobile")

	return &Config{
		ListenAddr:       "0.0.0.0:8765",
		HostName:         hostName,
		AntigravityDir:   agyDir,
		StateDBPath:      filepath.Join(cfgDir, "bridge_state.db"),
		AgentAPIBin:      filepath.Join(agyDir, "bin", "agentapi"),
		SubscriptionTier: "Google AI Ultra",
		Gemini5hBudget:   5_000_000,
		Gemini7dBudget:   50_000_000,
		Claude5hBudget:   3_000_000,
		Claude7dBudget:   30_000_000,
	}, nil
}

// DefaultConfigPath returns ~/.config/antigravity-mobile/config.json.
func DefaultConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".config", "antigravity-mobile", "config.json"), nil
}

// LoadOrCreate loads config from path or creates defaults on first run.
func LoadOrCreate(path string) (*Config, error) {
	cfg, err := DefaultConfig()
	if err != nil {
		return nil, err
	}
	if path == "" {
		path, err = DefaultConfigPath()
		if err != nil {
			return nil, err
		}
	}

	data, readErr := os.ReadFile(path)
	if readErr == nil {
		if err := json.Unmarshal(data, cfg); err != nil {
			return nil, fmt.Errorf("parse config %s: %w", path, err)
		}
	} else if !os.IsNotExist(readErr) {
		return nil, fmt.Errorf("read config %s: %w", path, readErr)
	}

	if cfg.BootstrapToken == "" {
		tok, err := GenerateToken()
		if err != nil {
			return nil, err
		}
		cfg.BootstrapToken = tok
		if err := Save(path, cfg); err != nil {
			return nil, err
		}
	}
	return cfg, nil
}

// Save writes config to disk with 0600 permissions.
func Save(path string, cfg *Config) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}

// GenerateToken produces a 256-bit cryptographically random API token.
func GenerateToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return "agy_live_" + hex.EncodeToString(buf), nil
}

// HashToken returns the hex-encoded SHA-256 hash of a bearer token.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// Port extracts the TCP port from ListenAddr (defaults to "8765").
func (c *Config) Port() string {
	_, port, err := net.SplitHostPort(c.ListenAddr)
	if err != nil || port == "" {
		return "8765"
	}
	return port
}

// BuildPairingPayload discovers local LAN and Tailscale IPs and produces the QR payload.
func (c *Config) BuildPairingPayload(token string) PairingPayload {
	endpoints := DiscoverEndpoints(c.Port(), c.PublicEndpoints)
	return PairingPayload{
		Version:   1,
		HostName:  c.HostName,
		Endpoints: endpoints,
		Token:     token,
	}
}

// DiscoverEndpoints returns ordered candidate HTTP endpoints: LAN first, Tailscale next, public last.
func DiscoverEndpoints(port string, publicEndpoints []string) []string {
	var lanIPs, tailscaleIPs []string

	ifaces, err := net.Interfaces()
	if err == nil {
		for _, iface := range ifaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, addr := range addrs {
				ipNet, ok := addr.(*net.IPNet)
				if !ok || ipNet.IP == nil {
					continue
				}
				ip4 := ipNet.IP.To4()
				if ip4 == nil || ip4.IsLoopback() || ip4.IsLinkLocalUnicast() {
					continue
				}
				switch {
				case IsTailscaleIP(ip4):
					tailscaleIPs = append(tailscaleIPs, ip4.String())
				case IsPrivateLANIP(ip4):
					lanIPs = append(lanIPs, ip4.String())
				}
			}
		}
	}

	sort.Strings(lanIPs)
	sort.Strings(tailscaleIPs)

	seen := make(map[string]struct{})
	out := make([]string, 0, len(lanIPs)+len(tailscaleIPs)+len(publicEndpoints))
	add := func(ep string) {
		ep = strings.TrimRight(strings.TrimSpace(ep), "/")
		if ep == "" {
			return
		}
		if _, ok := seen[ep]; ok {
			return
		}
		seen[ep] = struct{}{}
		out = append(out, ep)
	}

	for _, ip := range lanIPs {
		add(fmt.Sprintf("http://%s:%s", ip, port))
	}
	for _, ip := range tailscaleIPs {
		add(fmt.Sprintf("http://%s:%s", ip, port))
	}
	for _, ep := range publicEndpoints {
		add(ep)
	}
	if len(out) == 0 {
		add(fmt.Sprintf("http://127.0.0.1:%s", port))
	}
	return out
}

// IsTailscaleIP checks whether an IPv4 address lies in CGNAT 100.64.0.0/10.
func IsTailscaleIP(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	return ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127
}

// IsPrivateLANIP checks RFC1918 private IPv4 ranges.
func IsPrivateLANIP(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	if ip4[0] == 10 {
		return true
	}
	if ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31 {
		return true
	}
	if ip4[0] == 192 && ip4[1] == 168 {
		return true
	}
	return false
}
