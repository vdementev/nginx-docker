# nginx — static / SPA behind a reverse proxy

Tiny Alpine-based nginx image purpose-built for serving static sites
and SPAs **behind a reverse proxy** (HAProxy / Traefik / Angie /
nginx). TLS, HTTP/2, HTTP/3, and public-internet exposure are handled
by the proxy in front; this image just serves files fast and cheap.

`FROM` it, `COPY` your build into `/app`, done.

## Tags

| Tag           | Description                                                |
|---------------|------------------------------------------------------------|
| `latest`      | Latest build from `main`.                                  |
| `sha-<short>` | Pinned build by commit SHA (immutable).                    |
| `YYYYMMDD`    | Daily nightly tag (Alpine + nginx package refresh).        |

Multi-arch: `linux/amd64`, `linux/arm64`. SBOM and max-mode build
provenance attached to every image.

## Quick start

```dockerfile
FROM vdementev/nginx:latest
COPY --from=build /app/dist /app
```

The default vhost already does:

- `try_files $uri $uri/ /index.html` (SPA fallback for client-side routing).
- `/assets/` → `Cache-Control: public, immutable, max-age=31536000`.
- Images, fonts (svg/png/woff/woff2/…) → `Cache-Control: public, max-age=604800`.
- `/index.html` → `Cache-Control: no-store, must-revalidate`.
- Baseline security headers (HSTS, X-Frame-Options, Referrer-Policy,
  Permissions-Policy, X-Content-Type-Options) — CSP intentionally
  omitted, set per app.
- Trusts `X-Forwarded-For` from any RFC1918 / loopback / ULA hop, so
  `$remote_addr` and access logs reflect the real client IP.

## What's inside

- **Alpine 3.23** + **nginx** (apk-installed, tracks Alpine's package).
- **brotli static** (`nginx-mod-http-brotli`) — serves `.br` siblings.
- **zstd static** (`nginx-mod-http-zstd`) — serves `.zst` siblings.
- Runtime **gzip** as a universal fallback for anything without a
  precompressed sibling.
- **stub_status** on `:8080` for `nginx-prometheus-exporter`, plus
  `/healthz` on the same port for liveness probes.
- No `ca-certificates`, no `tzdata` (nginx never makes outbound TLS
  calls here, and logs are UTC).

## Default behaviour

- **`:80`** — site traffic, with `SO_REUSEPORT`. Serves `/app/`.
- **`:8080`** — internal-only. `stub_status` (RFC1918 + loopback ACL),
  `/healthz` (`ok`). **Never publish this port to the host.**
- **Healthcheck** — `wget http://127.0.0.1:8080/healthz` every 10s.

### Tuned for small footprint and low latency

- 2 workers × 512 connections each (1024 slots — well above any sane
  proxy pool). Override `worker_processes` downstream if you need more.
- `sendfile + tcp_nopush + tcp_nodelay`, `sendfile_max_chunk 2m` to
  keep tail latency predictable. No `aio threads` — page-cache hits
  dominate, threads sit idle.
- `open_file_cache` (2000 entries) — saves an `open()`+`fstat()` per
  request on hot paths.
- `absolute_redirect off` — redirects stay relative, so the internal
  container hostname can never leak via `Location:`.
- HTTP/1.1 only. HTTP/2 multiplexing buys nothing on a small persistent
  backend pool; HTTP/3 (QUIC/UDP) is pointless on a docker bridge with
  zero packet loss.

## Security note

Because `X-Forwarded-For` is trusted from any private range, **do NOT
publish `:80` directly to the public internet**. The trusted-proxy
assumption is what makes that safe — anyone who can reach `:80`
directly could spoof XFF.

## Custom vhost

To replace the default `:80` server block, ship your own
`/etc/nginx/conf.d/default.conf` and replace the inline `server { listen
80 … }` block in `/etc/nginx/nginx.conf` with `include
/etc/nginx/conf.d/*.conf;`. The `set_real_ip_from` /
`real_ip_header X-Forwarded-For` block lives at `http{}` level in the
base config, so any custom server block automatically gets correct
client IPs without per-vhost includes.

## Prometheus scrape

```yaml
services:
  nginx-exporter:
    image: nginx/nginx-prometheus-exporter:1.4.0
    command:
      - --nginx.scrape-uri=http://frontend:8080/stub_status
      - --nginx.scrape-uri=http://admin:8080/stub_status
    expose: ["9113"]
```

## Source

[github.com/vdementev/docker-nginx](https://github.com/vdementev/docker-nginx) · MIT license
