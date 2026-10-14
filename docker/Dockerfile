# VPS-Traffic-Tunnel inside a container (Railway, Fly.io, plain Docker).
#
# The image is Debian bookworm on purpose: the program is a plain Bash program
# written for Debian/Ubuntu and the installer uses apt-get. Xray-core itself is
# downloaded at run time (docker/entrypoint.sh), so `docker build` needs no
# network access beyond the base image.
#
#   docker build -f docker/Dockerfile -t vt-tunnel .
#   docker run -d --name vt --restart unless-stopped \
#     -p 24443:24443 -v vt-etc:/etc/vt vt-tunnel \
#     --mode reality --port 24443 --sni www.microsoft.com
#
# Railway: deploy this repository - the start command is already
# `docker/entrypoint.sh`, or set it explicitly in
# Settings > Deploy > Custom Start Command, together with a TCP Proxy whose
# target port is the tunnel port.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="VPS-Traffic-Tunnel" \
      org.opencontainers.image.description="Always-on VLESS tunnel with Xray-core, without systemd" \
      org.opencontainers.image.source="https://github.com/wrappedman/VPS-Traffic-Tunnel"

ENV DEBIAN_FRONTEND=noninteractive

# curl:  downloads Xray-core at run time (install.sh)
# jq:    reads/updates users.json
# iproute2 (ss): reports whether the tunnel port is listening
# procps: pgrep/kill for the process supervisor
# openssl, ca-certificates, unzip, socat: certificates, downloads, ACME http-01
# python3: fallbacks for JSON parsing and x25519
# cron:  keeps the acme.sh renewal job working on certificate modes
# socat in the list above is what acme.sh standalone needs for an IP certificate
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl jq openssl procps iproute2 python3 socat \
        unzip tar cron ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/log/vt /etc/vt

COPY . /opt/vt
RUN chmod +x /opt/vt/vt /opt/vt/bootstrap.sh /opt/vt/docker/entrypoint.sh \
    && ln -sf /opt/vt/vt /usr/local/bin/vt \
    && VT_ROOT= /opt/vt/vt help >/dev/null

# State (keys, users, certificates) lives here: mount a volume at /etc/vt if it
# has to survive a redeploy.
VOLUME ["/etc/vt"]

# Documentation only - the tunnel port is chosen by the install (or by --port).
EXPOSE 24443

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD ["/bin/sh", "-c", "/opt/vt/vt health --quiet || /opt/vt/vt status >/dev/null 2>&1"]

WORKDIR /opt/vt
ENTRYPOINT ["/opt/vt/docker/entrypoint.sh"]
