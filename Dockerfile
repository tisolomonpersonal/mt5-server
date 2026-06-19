FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/config/wine
ENV WINEARCH=win64
ENV DISPLAY=:1
ENV BRIDGE_PORT=8001

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        wget \
        unzip \
        procps \
        python3-minimal \
        xvfb \
        x11vnc \
        novnc \
        websockify \
        winbind \
        wine64 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 6080 8001

VOLUME ["/config"]

CMD ["/start.sh"]
