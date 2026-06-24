# mt5-server

Headless Docker service for running the Windows MetaTrader 5 terminal on Linux
through Wine and exposing the Python MetaTrader5 API through `mt5linux`.

This is intended for a server platform such as Zeabur. There is no desktop, VNC,
or browser UI. MT5 runs under Xvfb and logs in from environment variables.

## How it works

- `debian:bookworm-slim` runs `winehq-stable`.
- `Xvfb` provides the virtual display required by the MT5 GUI.
- On first boot, `/start.sh` creates `/config/.wine`, installs MT5, installs
  Windows Python 3.9.13, and installs the Windows `MetaTrader5` Python package.
- The Linux-side `mt5linux` bridge listens on `0.0.0.0:8001` by default.
- `/config` is a volume so the Wine prefix, MT5 install, and Windows Python can
  survive container restarts when the host platform attaches persistent storage.

## Zeabur deployment

Deploy this repository as a Docker service.

Set these environment variables in Zeabur:

| Variable | Required | Example |
| --- | --- | --- |
| `MT5_LOGIN` | yes | `12345678` |
| `MT5_PASSWORD` | yes | `your-password` |
| `MT5_SERVER` | yes | `Broker-Demo` |
| `BRIDGE_PORT` | no | `8001` |

Alternatively, provide the full MT5 command line yourself:

```text
MT5_CMD_OPTIONS=/login:12345678 /password:your-password /server:Broker-Demo
```

Expose port `8001` on the Zeabur service. If Zeabur injects a `PORT`
environment variable and `BRIDGE_PORT` is unset, the startup script will use
`PORT`.

Attach a persistent volume mounted at:

```text
/config
```

First boot can take several minutes because MT5 and Windows Python are installed
inside the Wine prefix. Later boots should reuse `/config/.wine`.

## Client usage

Install `mt5linux` in your trading client, then connect to the Zeabur host:

```python
from mt5linux import MetaTrader5

mt5 = MetaTrader5(host="<your-zeabur-host>", port=8001)
mt5.initialize()
```

Keep your trading account credentials in Zeabur environment variables only. Do
not commit passwords, account numbers, broker secrets, or strategy secrets to
this repository.

## Troubleshooting

- If startup logs say `terminal64.exe was not created`, delete the attached
  `/config` volume and redeploy so Wine can create a clean prefix.
- If `mt5.initialize()` fails from the client, confirm the Zeabur TCP port is
  exposed and the broker server name exactly matches the server shown by your
  broker.
- If the first login fails, some brokers require an interactive first login or
  additional 2FA/OTP approval. This headless image cannot complete interactive
  login prompts.
