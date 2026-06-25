FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV DISPLAY=:99
ENV PIP_BREAK_SYSTEM_PACKAGES=1

# Wine + virtual display + Python — all in one layer
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
    python3-pkg-resources \
    python3-setuptools \
 && mkdir -pm755 /etc/apt/keyrings \
 && wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key \
 && wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install --install-recommends -y winehq-stable \
 && python3 -m pip install --no-cache-dir --upgrade pip \
 && python3 -m pip install --no-cache-dir mt5linux rpyc plumbum numpy \
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

# Pre-download all installers into the image so startup never needs internet
# (these are large but save several minutes on every container restart)
RUN mkdir -p /opt/installers \
 && curl -fL -o /opt/installers/mono.msi \
    "https://dl.winehq.org/wine/wine-mono/10.3.0/wine-mono-10.3.0-x86.msi" \
 && curl -fL -o /opt/installers/python-installer.exe \
    "https://www.python.org/ftp/python/3.9.13/python-3.9.13.exe" \
 && curl -fL -o /opt/installers/mt5setup.exe \
    "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" \
 && echo "Installers cached:" \
 && ls -lh /opt/installers/

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8001

# /config must be a persistent volume on Zeabur — mount it to survive restarts
VOLUME ["/config"]

CMD ["/start.sh"]
