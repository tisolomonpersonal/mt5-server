FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/wine
ENV WINEARCH=win64
ENV DISPLAY=:1

# Install Wine, VNC tools, Python, and utilities
RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y \
        wget curl cabextract \
        xvfb x11vnc \
        novnc websockify \
        python3 python3-pip \
        winbind wine wine32:i386 wine64 \
    && pip3 install mt5linux \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

# 6080 = noVNC browser interface
# 8001 = mt5linux Python RPC bridge (used by the trading bot)
EXPOSE 6080 8001

# /config is the persistent volume — mount it in Zeabur to survive restarts
VOLUME ["/config"]

CMD ["/start.sh"]
