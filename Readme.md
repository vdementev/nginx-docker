# nginx

Reusable nginx base image for static sites and SPAs, designed to live
**behind a reverse proxy** (HAProxy / Traefik / Angie / nginx) on a
docker network. TLS, HTTP/2, public-internet exposure are handled by
the proxy in front; this layer just serves files fast and cheap.

`FROM` it in your project's Dockerfile, drop your build output into
`/app`, and you're done.

## What's in the image

- **Alpine 3.23** + **nginx** (apk-installed, follows Alpine's nginx track).
- **brotli** static module (`nginx-mod-http-brotli`).
- **zstd** static module (`nginx-mod-http-zstd`).
- **stub_status** on a separate metrics server (`:8080`) for
  `nginx-prometheus-exporter` scrape, with `/healthz` for liveness.
- No `ca-certificates`, no `tzdata` — this nginx makes no outbound TLS
  calls and logs in UTC. Add either back in a downstream image if needed.

## Default behaviour

- Listens on `:80` (with `SO_REUSEPORT`), serves `/app/` as an SPA:
  - `try_files $uri $uri/ /index.html` for client-side routing.
  - `/assets/` cached `1y, immutable` (Vite/webpack content-hashed names).
  - Other static assets (svg/png/woff/…) cached `7d`.
  - `/index.html` served `no-store` (per-request CSP nonce friendly).
- Emits baseline security headers (HSTS, X-Frame-Options,
  Referrer-Policy, Permissions-Policy, X-Content-Type-Options). CSP is
  intentionally not set — tune per app.
- Trusts `X-Forwarded-For` from any RFC1918 / loopback / ULA hop, so
  `$remote_addr` and access logs reflect the real client IP.
- Returns `pong` on `/ping` (loopback only).
- Listens on `:8080`, exposes `stub_status` (RFC1918 + loopback) and
  `/healthz` (returns `ok`).
- Compression: pre-compressed `.br` / `.zst` / `.gz` siblings served
  via `*_static`. Runtime brotli/zstd are off (the proxy in front does
  any re-encoding); gzip stays on as a runtime fallback.
- File-descriptor + stat cache (`open_file_cache`, 2000 entries).
- `absolute_redirect off` — redirects stay relative so the internal
  container hostname can't leak via `Location:`.
- Healthcheck: `wget http://127.0.0.1:8080/healthz` every 10s.

### Tuning targets

Tuned for "small footprint, fast on the hot path":

- 2 workers, 512 connections each (1024 slots — well above any sane
  proxy pool). Override with `worker_processes` in a downstream
  `nginx.conf` if you need more.
- Sized for static delivery: `sendfile + tcp_nopush + tcp_nodelay`,
  `sendfile_max_chunk 2m` to keep tail latency predictable, no `aio`
  (page-cache hits dominate; threads sat idle).
- HTTP/1.1 only on the proxy hop. HTTP/2 multiplexing buys nothing on a
  small persistent backend pool, and HTTP/3 (QUIC/UDP) is pointless on
  a docker bridge with zero packet loss.

> **Security note:** because XFF is trusted from any private range, do
> NOT publish `:80` directly to the public internet — the trusted-proxy
> assumption is what makes that safe.

## Using as a base

```dockerfile
# Your project's Dockerfile
FROM <registry>/<user>/nginx:latest
COPY --from=build /app/dist /app
```

That's it for an SPA — the default vhost already does try_files,
caching, and security headers.

### Custom vhost

To replace the default `:80` server block, ship your own
`/etc/nginx/conf.d/default.conf` — but FIRST replace the inline `server
{ listen 80 … }` block in `/etc/nginx/nginx.conf` with
`include /etc/nginx/conf.d/*.conf;` (the default config doesn't
auto-include `conf.d/`; that's deliberate, so the simplest case stays
single-file).

The `set_real_ip_from` / `real_ip_header X-Forwarded-For` block is at
`http{}` level in the base config, so any custom server block
automatically gets correct client IPs without per-vhost includes.

## Prometheus

Drop a `nginx-prometheus-exporter` sidecar in compose and point it at
`<this-container>:8080/stub_status`. One exporter can scrape multiple
nginx containers via repeated `--nginx.scrape-uri=...`.

```yaml
services:
  nginx-exporter:
    image: nginx/nginx-prometheus-exporter:1.4.0
    command:
      - --nginx.scrape-uri=http://frontend:8080/stub_status
      - --nginx.scrape-uri=http://admin:8080/stub_status
    expose: ["9113"]
```

## CI

`.github/workflows/docker-build-push.yml` builds linux/amd64 +
linux/arm64 on every push to `main` and pushes to Docker Hub as
`${DOCKERHUB_USERNAME}/nginx:latest`. SBOM + max provenance enabled.

## Versioning

Tracks Alpine's nginx package. To pin a specific upstream nginx version,
override the apk install in a downstream Dockerfile:

```dockerfile
FROM alpine:3.23
RUN apk add nginx=1.28.0-r0 nginx-mod-http-brotli nginx-mod-http-zstd
```
