FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/wine
ENV WINEARCH=win64
ENV DISPLAY=:1
ENV BRIDGE_PORT=8001

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y \
        wget curl cabextract unzip procps \
        xvfb x11vnc \
        novnc websockify \
        python3 python3-pip \
        winbind wine wine32:i386 wine64 \
    && pip3 install --no-cache-dir mt5linux \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 6080 8001

VOLUME ["/config"]

CMD ["/start.sh"]
