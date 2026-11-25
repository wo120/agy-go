package tsfunnel

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"tailscale.com/net/tshttpproxy"
)

const defaultNoProxy = "127.0.0.1,localhost,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

// ensureSystemProxyForTsnet mirrors the OS system proxy (macOS scutil / Windows Internet Settings)
// into HTTPS_PROXY/HTTP_PROXY when absent so tsnet can reach controlplane.tailscale.com even
// when a desktop proxy (such as Clash/Mihomo in Fake-IP system-proxy mode) is active.
func ensureSystemProxyForTsnet() string {
	for _, key := range []string{"HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			tshttpproxy.InvalidateCache()
			return v
		}
	}

	proxyURL := detectSystemProxy()
	if proxyURL == "" {
		return ""
	}

	_ = os.Setenv("HTTPS_PROXY", proxyURL)
	_ = os.Setenv("HTTP_PROXY", proxyURL)
	if strings.TrimSpace(os.Getenv("NO_PROXY")) == "" && strings.TrimSpace(os.Getenv("no_proxy")) == "" {
		_ = os.Setenv("NO_PROXY", defaultNoProxy)
	}
	tshttpproxy.InvalidateCache()
	log.Printf("[agy-remote] detected OS system proxy for tsnet: %s", proxyURL)
	return proxyURL
}

func detectSystemProxy() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	switch runtime.GOOS {
	case "darwin":
		out, err := exec.CommandContext(ctx, "scutil", "--proxy").Output()
		if err != nil {
			return ""
		}
		return parseDarwinScutilProxy(string(out))
	case "windows":
		out, err := exec.CommandContext(
			ctx,
			"reg",
			"query",
			`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`,
		).Output()
		if err != nil {
			return ""
		}
		return parseWindowsRegProxy(string(out))
	default:
		return ""
	}
}

func parseDarwinScutilProxy(raw string) string {
	kv := make(map[string]string)
	for _, line := range strings.Split(raw, "\n") {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}
		k := strings.TrimSpace(parts[0])
		v := strings.TrimSpace(parts[1])
		if k != "" && v != "" {
			kv[k] = v
		}
	}

	if kv["HTTPSEnable"] == "1" && kv["HTTPSProxy"] != "" && kv["HTTPSPort"] != "" {
		return fmt.Sprintf("http://%s:%s", kv["HTTPSProxy"], kv["HTTPSPort"])
	}
	if kv["HTTPEnable"] == "1" && kv["HTTPProxy"] != "" && kv["HTTPPort"] != "" {
		return fmt.Sprintf("http://%s:%s", kv["HTTPProxy"], kv["HTTPPort"])
	}
	if kv["SOCKSEnable"] == "1" && kv["SOCKSProxy"] != "" && kv["SOCKSPort"] != "" {
		return fmt.Sprintf("socks5://%s:%s", kv["SOCKSProxy"], kv["SOCKSPort"])
	}
	return ""
}

func parseWindowsRegProxy(raw string) string {
	enabled := false
	server := ""
	for _, line := range strings.Split(raw, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		switch strings.ToLower(fields[0]) {
		case "proxyenable":
			val := strings.ToLower(fields[len(fields)-1])
			enabled = val == "0x1" || val == "1"
		case "proxyserver":
			server = strings.TrimSpace(fields[len(fields)-1])
		}
	}
	if !enabled || server == "" {
		return ""
	}

	// Windows ProxyServer can be either "127.0.0.1:7897" or "http=127.0.0.1:7897;https=127.0.0.1:7897".
	if strings.Contains(server, "=") {
		picked := ""
		for _, seg := range strings.Split(server, ";") {
			kv := strings.SplitN(strings.TrimSpace(seg), "=", 2)
			if len(kv) != 2 {
				continue
			}
			scheme := strings.ToLower(strings.TrimSpace(kv[0]))
			addr := strings.TrimSpace(kv[1])
			if scheme == "https" && addr != "" {
				picked = addr
				break
			}
			if scheme == "http" && addr != "" && picked == "" {
				picked = addr
			}
			if scheme == "socks" && addr != "" && picked == "" {
				picked = "socks5://" + addr
			}
		}
		server = picked
	}
	if server == "" {
		return ""
	}
	if strings.Contains(server, "://") {
		return server
	}
	return "http://" + server
}
