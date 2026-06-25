FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV DISPLAY=:99

# 1. System packages + WineHQ stable
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates wget curl gnupg2 \
      xvfb winbind cabextract \
      python3 python3-pip procps iproute2 \
 && mkdir -pm755 /etc/apt/keyrings \
 && wget -O /etc/apt/keyrings/winehq-archive.key \
      https://dl.winehq.org/wine-builds/winehq.key \
 && wget -NP /etc/apt/sources.list.d/ \
      https://dl.winehq.org/wine-builds/debian/dists/bookworm/winehq-bookworm.sources \
 && apt-get update \
 && apt-get install --install-recommends -y winehq-stable \
 && apt-get purge -y --auto-remove gnupg2 \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 2. Python bridge library
RUN pip3 install --no-cache-dir --break-system-packages mt5linux rpyc

# 3. Pre-download MT5 installer (avoids slow download on every container start)
RUN curl -fL -o /opt/mt5setup.exe \
      "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8001

# Mount a persistent volume at /config on Zeabur so Wine prefix survives restarts
VOLUME ["/config"]

CMD ["/start.sh"]
