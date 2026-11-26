# agy-remote Plugin Rules

When the user asks to check remote mobile connection status, display mobile pairing QR/endpoints, or send a notification/reminder to their phone:

1. Use the `agy-remote` MCP tools (`agy_remote_status`, `agy_remote_tps`, `agy_remote_pairing_info`, `agy_remote_notify_mobile`) instead of running manual shell probes.
2. When visual QR scanning or token rotation is helpful, offer the Antigravity Aux Pane link `[agy-remote](sidecar://agy-remote/remote/)`.
3. Never print or expose raw bearer tokens to untrusted public channels unless the user explicitly asks for the pairing JSON to connect their own device.
