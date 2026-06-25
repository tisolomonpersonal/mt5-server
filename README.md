# mt5-server

Runs MetaTrader 5 inside Wine on a Linux container and exposes the
[mt5linux](https://github.com/lucas-campagna/mt5linux) RPyC bridge on port 8001
so that Python bots can connect remotely.

## Required: Persistent Volume on Zeabur

Add a persistent volume mounted at `/config` before the first deploy.
Without it, Wine reinitialises from scratch on every restart (~5-8 min).
With it, first boot is slow once — every restart after is under 30 seconds.

## Environment Variables

| Variable | Required | Example |
|---|---|---|
| `MT5_LOGIN` | No | `12345678` |
| `MT5_PASSWORD` | No | `mypassword` |
| `MT5_SERVER` | No | `Bybit-Demo` |
| `BRIDGE_PORT` | No | `8001` (default) |

## Connecting from Python

```python
from mt5linux import MetaTrader5
mt5 = MetaTrader5(host="mt5-server.zeabur.internal", port=8001)
mt5.initialize()
print(mt5.account_info())
```

## Startup sequence

1. Xvfb virtual display
2. Wine prefix init (first boot only, ~5 min, persists in `/config`)
3. MT5 install (first boot only, persists in `/config`)
4. MT5 terminal launch
5. mt5linux RPyC bridge on port 8001
