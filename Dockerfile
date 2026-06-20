FROM ghcr.io/linuxserver/baseimage-kasmvnc:debianbookworm

ARG BUILD_DATE
ARG VERSION
LABEL build_version="MT5 Server:- ${VERSION} Build-date:- ${BUILD_DATE}"
LABEL maintainer="tisolomonpersonal"

ENV TITLE=MetaTrader5
ENV WINEPREFIX="/config/.wine"
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# Install Wine, Python and tooling in a single layer, then aggressively slim it
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        wget \
        curl \
        gnupg2 \
        software-properties-common \
        ca-certificates \
    && mkdir -pm755 /etc/apt/keyrings \
    && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
    && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
    && dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get install --install-recommends -y winehq-stable \
    && apt-get purge -y --auto-remove software-properties-common gnupg2 \
    && apt-get clean \
    # ── Strip weight we never use at runtime ──────────────────────────────────
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* /var/tmp/* \
        /etc/apt/keyrings/winehq-archive.key \
        /usr/share/doc/* \
        /usr/share/man/* \
        /usr/share/info/* \
        /usr/share/lintian/* \
        /usr/share/locale/* \
        /opt/wine-stable/share/man/* \
        /opt/wine-stable/share/doc/*

COPY /Metatrader /Metatrader
RUN chmod +x /Metatrader/start.sh
COPY /root /

# 3000 = browser VNC (KasmVNC), 8001 = mt5linux RPyC bridge
EXPOSE 3000 8001
VOLUME /config
