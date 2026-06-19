FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/wine
ENV WINEARCH=win64
ENV DISPLAY=:1
ENV BRIDGE_PORT=8001

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        unzip \
        procps \
        xvfb \
        winbind \
        cabextract \
        p7zip-full \
        gnupg2 \
        software-properties-common \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install -y --install-recommends \
        winehq-stable \
        winetricks \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /etc/apt/keyrings/winehq-archive.key

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8001

VOLUME ["/config"]

CMD ["/start.sh"]
