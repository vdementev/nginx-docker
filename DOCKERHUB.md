# nginx — static / SPA behind a reverse proxy

Tiny Alpine-based nginx image purpose-built for serving static sites
and SPAs **behind a reverse proxy** (HAProxy / Traefik / Angie /
nginx). TLS, HTTP/2, HTTP/3, and public-internet exposure are handled
by the proxy in front; this image just serves files fast and cheap.

`FROM` it, `COPY` your build into `/app`, done.

## Tags

| Tag | Contents |
|---|---|
| `latest` | The newest build — every merge to `main`, plus a weekly rebuild for package updates. |
| `1.30.4` | The exact nginx version inside the image. |
| `1.30` | The newest patch of that nginx minor. |

Version tags are read out of the image *after* it is built and tested, so a tag
can never claim a version the image does not run.

Multi-arch: `linux/amd64`, `linux/arm64`. SBOM, max-mode build provenance and a
Cosign keyless signature on every published digest.

## Quick start

```dockerfile
FROM dementev/nginx:latest
COPY --from=build /app/dist /app
```

The default vhost already does:

- `try_files $uri $uri/ /index.html` (SPA fallback for client-side routing).
- `/assets/` → `Cache-Control: public, immutable, max-age=31536000`.
- Images, fonts (svg/png/woff/woff2/…) → `Cache-Control: public, max-age=604800`.
- `/index.html` → `Cache-Control: no-store, must-revalidate`.
- Baseline security headers (HSTS, X-Frame-Options, Referrer-Policy,
  Permissions-Policy, X-Content-Type-Options) on **every** response —
  CSP intentionally omitted, set per app.
- Trusts `X-Forwarded-For` from any RFC1918 / loopback / ULA hop, so
  `$remote_addr` and access logs reflect the real client IP.

## What's inside

- **Alpine stable** (`alpine:latest`, currently 3.24) + **nginx 1.30.x**
  (apk-installed, tracks Alpine's package).
- **brotli static** (`nginx-mod-http-brotli`) — serves `.br` siblings.
- **zstd static** (`nginx-mod-http-zstd`) — serves `.zst` siblings.
- Runtime **gzip** as a universal fallback for anything without a
  precompressed sibling.
- **stub_status** on `:8080` for `nginx-prometheus-exporter`, plus
  `/healthz` on the same port for liveness probes.
- No `ca-certificates`, no `tzdata` (nginx never makes outbound TLS
  calls here, and logs are UTC).
- Optional rootless mode: `NGINX_DROP_MASTER=true` runs the master as
  `nginx` instead of root.

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
- Buffered access log (`buffer=32k flush=5s`) — one `write()` per
  ~32 KiB instead of one per request, so the Docker log driver can't
  turn logging into request latency. Logs lag up to 5s.
- `keepalive_requests 10000` — the peer is a proxy holding a small
  persistent pool, not a browser; the default 1000 would force a
  pointless TCP re-handshake every 1000 requests.
- `absolute_redirect off` — redirects stay relative, so the internal
  container hostname can never leak via `Location:`.
- HTTP/1.1 only. HTTP/2 multiplexing buys nothing on a small persistent
  backend pool; HTTP/3 (QUIC/UDP) is pointless on a docker bridge with
  zero packet loss.

## Do not publish `:80` directly

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

## Security and provenance

Every published digest is built by the shared pipeline in
[vdementev/docker-workflows](https://github.com/vdementev/docker-workflows).
Pull requests build, test and scan without publishing; `main` is
branch-protected, so nothing reaches Docker Hub without a green check behind it.
A Trivy gate fails the build on any *fixable* CRITICAL or HIGH finding, and each
published digest carries an SBOM, max-mode SLSA provenance and a keyless Cosign
signature.

Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp 'github.com/vdementev/' \
  dementev/nginx:latest
```

[SECURITY.md](https://github.com/vdementev/nginx-docker/blob/main/SECURITY.md) is the reporting channel and the response
targets; [SUPPORT.md](https://github.com/vdementev/nginx-docker/blob/main/SUPPORT.md) covers tag lifecycle, pinning and
patch cadence.

## Related images

One family, built by the same pipeline, meant to run together — a proxy in
front, an app runtime, a database, and a way into it.

| Image | What it does |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) — [source](https://github.com/vdementev/angie-docker) | Public-facing reverse proxy and TLS terminator — Angie, the nginx fork, with brotli, zstd and cache-purge |
| **[`dementev/nginx`](https://hub.docker.com/r/dementev/nginx)** — this image | Static sites and SPAs behind that proxy — brotli/zstd siblings, Prometheus stub_status |
| [`dementev/php-fpm-with-ext`](https://hub.docker.com/r/dementev/php-fpm-with-ext) — [source](https://github.com/vdementev/docker-php-fpm-with-ext) | PHP-FPM and CLI, PHP 7.0 → 8.5, with the extensions most projects reach for |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) — [source](https://github.com/vdementev/mysql-percona-docker) | Percona Server for MySQL 8.4 LTS, XtraBackup built in, no root inside |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) — [source](https://github.com/vdementev/adminer-docker) | Adminer 6 with every driver it supports, for reaching any of the above |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). These images are not a side
project — they are the base layer under the client and product systems we run,
which is why they are gated, tested and signed rather than pushed by hand.

Issues and pull requests:
[github.com/vdementev/nginx-docker](https://github.com/vdementev/nginx-docker).
Need this kind of infrastructure built or maintained for your own stack?
[lotuswebagency.com](https://lotuswebagency.com).

Packaging in this repository is MIT licensed — see
[LICENSE](https://github.com/vdementev/nginx-docker/blob/main/LICENSE). The software
inside the image keeps its own upstream licenses.
