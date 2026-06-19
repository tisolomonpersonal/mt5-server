# mt5-server

Wine-based MetaTrader 5 bridge for `eth-trader-bot`.

## Why This Was Failing

The Zeabur crash:

```text
wine: Call from ... to unimplemented function
api-ms-win-crt-runtime-l1-1-0.dll.fetestexcept
```

was happening while importing the Windows `MetaTrader5` Python package inside Wine. That means the container was failing before the RPC bridge ever came up.

## Fix Applied

- Switched from Ubuntu distro `wine` packages to Debian Bookworm + `winehq-stable`
- Added `winetricks` and installs `vcrun2019` into the persistent Wine prefix
- Moved the embedded Windows Python default from `3.11` to `3.9.13`
- Added cleanup and forced reinstall logic for stale Windows-side packages
- Kept the bridge port on `8001`

## Optional Environment Overrides

- `BRIDGE_PORT`: defaults to `8001`
- `PYTHON_EMBED_VERSION`: defaults to `3.9.13`

## Deploy Notes

- Rebuild and redeploy the `mt5-server` service on Zeabur
- Because your `/config` volume persists, the new startup script will install the native VC runtime once and reuse it on later boots
- If Zeabur still reuses a broken old prefix, delete the service volume once and redeploy so `/config/wine` is recreated cleanly
