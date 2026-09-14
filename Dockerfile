# syntax=docker/dockerfile:1
# Reusable nginx base image — designed to live BEHIND a reverse proxy
# (HAProxy / Traefik / Angie / nginx) on a docker network.
#
# nginx + brotli + zstd dynamic modules, plus a separate metrics server
# on :8080 exposing nginx's stub_status for nginx-prometheus-exporter.
#
# Consumers (e.g. an SPA repo, a static-site repo): FROM <this image>,
# drop their site into /app, and (optionally) supply their own
# /etc/nginx/conf.d/default.conf for a non-default vhost. The included
# nginx.conf serves /app on :80 with SPA-friendly defaults, baseline
# security headers, and X-Forwarded-For trust for any RFC1918/ULA hop.

# Current Alpine stable, floating. Not `edge`: edge ships the same nginx
# 1.30.x, so tracking it bought nothing but the risk of a toolchain or
# ABI change landing mid-rebuild. Nothing here is version-pinned — the
# weekly rebuild picks up new base images and packages on its own, and
# every build runs tests.sh and the Trivy gate before it can publish.
FROM mirror.gcr.io/library/alpine:latest

# OCI metadata. Source/url/title/licenses can be overridden at build time
# via --label so downstream projects don't have to fork this Dockerfile.
LABEL org.opencontainers.image.title="nginx"
LABEL org.opencontainers.image.description="Reusable nginx base — brotli + zstd + Prometheus stub_status."
LABEL org.opencontainers.image.source="https://github.com/vdementev/docker-nginx"
LABEL org.opencontainers.image.licenses="MIT"

# Entrypoint knobs. NGINX_DROP_MASTER=true runs the master as NGINX_USER
# instead of root; see docker-entrypoint.sh.
ENV NGINX_USER=nginx

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    apk update; \
    apk upgrade --no-interactive; \
    apk add --no-cache \
        nginx \
        nginx-mod-http-brotli \
        nginx-mod-http-zstd \
        su-exec; \
    # Tidy: apk caches, root .cache, /tmp, manpages, nginx docs and the
    # logrotate wiring — dead weight in a container that logs to stdout.
    # Keeps the final image close to the bare nginx footprint.
    # Note: ca-certificates and tzdata are NOT installed — this nginx
    # makes no outbound TLS calls (no proxy_pass over HTTPS, no DNS
    # resolver) and logs in UTC. If a downstream image needs either,
    # add `apk add ca-certificates tzdata`.
    rm -rf /var/cache/apk/* /root/.cache /tmp/* /usr/share/man /usr/share/doc \
           /etc/logrotate.d/nginx; \
    # Hardening: nothing in this image needs to escalate. Alpine ships no
    # setuid binary today, so this is a guard against a future package
    # quietly adding one, not a fix for anything present.
    find / -xdev -type f -perm /6000 -exec chmod a-s '{}' +

COPY --chmod=0644 ./conf/ /etc/nginx/

# Build-time gate: a typo in the baked config fails the build instead of
# crash-looping a container at deploy time.
#
# `nginx -t` runs as root here and leaves root-owned droppings behind — the
# prefix-relative error log (hence -e) and the pid file — which a non-root
# master (NGINX_DROP_MASTER=true) then can't write, so it dies at startup.
RUN set -eux; \
    nginx -t -e /dev/stderr; \
    rm -f /run/nginx/nginx.pid

WORKDIR /app

# 80   — site traffic
# 8080 — Prometheus stub_status + healthz (scrape target; never publish to the host)
EXPOSE 80/tcp 8080/tcp

# wget is busybox-provided in alpine. /healthz returns 200 from the
# metrics server even before any /app content exists. Exec form: no
# /bin/sh fork per probe.
HEALTHCHECK --interval=10s --timeout=2s --start-period=5s --retries=3 \
    CMD ["wget", "-q", "-T", "2", "-t", "1", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]

STOPSIGNAL SIGQUIT
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
