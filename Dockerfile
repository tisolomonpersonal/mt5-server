FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV DISPLAY=:99
ENV BRIDGE_PORT=8001

# Wine + a virtual display (no VNC/desktop) + Python, slimmed in one layer
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    curl \
    gnupg2 \
    xvfb \
    winbind \
    cabextract \
    procps \
    iproute2 \
    python3 \
    python3-pip \
 && mkdir -pm755 /etc/apt/keyrings \
 && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install --install-recommends -y winehq-stable \
 && apt-get purge -y --auto-remove gnupg2 \
 && apt-get clean \
 && rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* /var/tmp/* \
    /etc/apt/keyrings/winehq-archive.key \
    /usr/share/doc/* \
    /usr/share/man/* \
    /usr/share/info/* \
    /usr/share/locale/* \
    /opt/wine-stable/share/man/* \
    /opt/wine-stable/share/doc/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8001
VOLUME ["/config"]

CMD ["/start.sh"]
