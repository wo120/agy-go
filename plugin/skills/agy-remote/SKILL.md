---
name: agy-remote
description: Manage the agy-remote Antigravity mobile companion plugin — check LAN/Tailscale bridge status, show pairing QR panel in the Antigravity side pane, inspect 5h/7d quota, or push instant notifications to connected Android phones.
---

# agy-remote Plugin Workflow

`agy-remote` packages the Mac-side Antigravity mobile bridge into a native Antigravity plugin:
- **Managed Sidecar (`sidecars/remote`)**: Starts automatically with Antigravity, listens on `0.0.0.0:8765` for the Android Levity app (LAN / Tailscale direct HTTP RPC + `/api/v1/mux` WebSocket), and renders the live QR Pairing & Quota dashboard inside Antigravity's Aux Pane.
- **Lifecycle Hooks (`hooks.json`)**: Forwards `Stop` (task completion) and `PostToolUse(ask_question)` (decision confirmation) to connected mobile devices in milliseconds.
- **MCP Tools (`agy-remote`)**:
  - `agy_remote_status` — inspect bridge health, direct endpoints, desktop online state, and 5h/7d model quota snapshot.
  - `agy_remote_pairing_info` — fetch pairing endpoints and JSON payload for the Android app.
  - `agy_remote_notify_mobile` — send a custom high-priority push notification (e.g., morning briefing, long task milestone, or confirmation prompt with quick replies) to connected Android devices.

## Opening the Pairing QR Panel
When the user wants to pair their phone, view the QR code, rotate the token, or trigger a test notification visually, surface the Aux Pane sidecar link:

`[agy-remote](sidecar://agy-remote/remote/)`

## Rebuilding / Updating the Plugin Binary
From the repository root, run:

```bash
./scripts/install-plugin.sh
```
