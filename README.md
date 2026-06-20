# mt5-server

Wine-based MetaTrader 5 bridge for `eth-trader-bot`, built on the proven
[linuxserver KasmVNC](https://github.com/linuxserver/docker-baseimage-kasmvnc)
base image (same architecture as
[gmag11/MetaTrader5-Docker](https://github.com/gmag11/MetaTrader5-Docker)).

## Architecture

- **Base image:** `ghcr.io/linuxserver/baseimage-kasmvnc:debianbookworm` —
  provides the X display, VNC server, browser web client, and s6 supervisor.
  No hand-rolled Xvfb / x11vnc / websockify (that stack was the source of the
  earlier crash-loops).
- **Wine + winehq-stable** runs the Windows MT5 terminal and a full Windows
  Python (3.9.13).
- **mt5linux RPyC bridge** is started from the Linux side via
  `python3 -m mt5linux ... -w wine python.exe` and exposes the MetaTrader5 API.
- **`Metatrader/start.sh`** is launched by the base image through
  `root/defaults/autostart` (openbox autostart). There is **no** server-side
  `mt5.initialize()` readiness loop — the terminal is logged in via the GUI and
  `initialize()` is called by the **client** (eth-trader-bot).

## Ports

| Port | Purpose |
|------|---------|
| 3000 | Browser VNC — open `https://<your-zeabur-domain>/` (KasmVNC) |
| 8001 | mt5linux RPyC bridge (the Python API endpoint) |

## Logging in to MT5

1. Deploy and open the port-3000 web URL in your browser.
2. The MT5 terminal appears on the desktop — log in to your broker account
   in the GUI (File → Login to Trade Account).
3. Once logged in, the bridge on port 8001 relays API calls.

To auto-login on boot instead, set `MT5_CMD_OPTIONS`:

```text
MT5_CMD_OPTIONS=/login:12345 /password:yourpass /server:Broker-Demo
```

## Environment Overrides

- `BRIDGE_PORT` — RPyC bridge port (default `8001`)
- `MT5_CMD_OPTIONS` — extra terminal command-line flags (e.g. auto-login)

## Deploy Notes (Zeabur)

- Expose **port 3000** (browser access) and **8001** (bridge).
- The `/config` volume persists Wine, MT5, and Python installs across reboots —
  first boot installs everything (a few minutes), later boots reuse it.
- If a previous broken prefix is reused, delete the service volume once and
  redeploy so `/config/.wine` is recreated cleanly.
