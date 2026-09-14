# nginx

Reusable nginx base image for static sites and SPAs, designed to live
**behind a reverse proxy** (HAProxy / Traefik / Angie / nginx) on a
docker network. TLS, HTTP/2, public-internet exposure are handled by
the proxy in front; this layer just serves files fast and cheap.

`FROM` it in your project's Dockerfile, drop your build output into
`/app`, and you're done.

## What's in the image

- **Alpine 3.24** (stable, pinned by digest) + **nginx 1.30.x**
  (apk-installed, follows Alpine's nginx track).
- **brotli** static module (`nginx-mod-http-brotli`).
- **zstd** static module (`nginx-mod-http-zstd`).
- **stub_status** on a separate metrics server (`:8080`) for
  `nginx-prometheus-exporter` scrape, with `/healthz` for liveness.
- `su-exec` + a 30-line entrypoint, for the optional rootless mode below.
- No `ca-certificates`, no `tzdata` — this nginx makes no outbound TLS
  calls and logs in UTC. Add either back in a downstream image if needed.

Alpine **stable**, not `edge`: edge happens to carry the same nginx
1.30.x, so tracking it bought nothing but the risk of a toolchain or
ABI change landing in the middle of a weekly rebuild. The stable branch
carries the same CVE backports on a predictable cadence.

## Default behaviour

- Listens on `:80` (with `SO_REUSEPORT`), serves `/app/` as an SPA:
  - `try_files $uri $uri/ /index.html` for client-side routing.
  - `/assets/` cached `1y, immutable` (Vite/webpack content-hashed names).
  - Other static assets (svg/png/woff/…) cached `7d`.
  - `/index.html` served `no-store` (per-request CSP nonce friendly).
- Emits baseline security headers (HSTS, X-Frame-Options,
  Referrer-Policy, Permissions-Policy, X-Content-Type-Options) on
  **every** response. CSP is intentionally not set — tune per app.
- Trusts `X-Forwarded-For` from any RFC1918 / loopback / ULA hop, so
  `$remote_addr` and access logs reflect the real client IP.
- Returns `pong` on `/ping`.
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
- **Buffered access log** (`buffer=32k flush=5s`) — one `write()` per
  ~32 KiB instead of one per request. The Docker log driver reads
  stdout through a pipe and `json-file` can block the writing worker,
  so unbuffered logging shows up as request latency under load. Cost:
  logs lag by up to 5s, and the tail is lost on `SIGKILL` (a graceful
  `SIGQUIT` stop flushes).
- `keepalive_requests 10000` — the only client is the proxy in front,
  reusing a handful of long-lived connections; nginx's default of 1000
  forces a needless TCP re-handshake every 1000 requests.
- `reset_timedout_connection on`, `log_not_found off`.
- HTTP/1.1 only on the proxy hop. HTTP/2 multiplexing buys nothing on a
  small persistent backend pool, and HTTP/3 (QUIC/UDP) is pointless on
  a docker bridge with zero packet loss.

> **Security note:** because XFF is trusted from any private range, do
> NOT publish `:80` directly to the public internet — the trusted-proxy
> assumption is what makes that safe.

## Using as a base

```dockerfile
# Your project's Dockerfile
FROM dementev/nginx:latest
COPY --from=build /app/dist /app
```

That's it for an SPA — the default vhost already does try_files,
caching, and security headers.

### Rootless mode

The master runs as root by default and the `user nginx;` directive
handles worker privilege separation, matching the stock nginx image.
Set `NGINX_DROP_MASTER=true` to run the master as `nginx` too:

```yaml
services:
  frontend:
    image: dementev/nginx:latest
    environment:
      NGINX_DROP_MASTER: "true"
```

Ports 80/8080 still bind (Docker sets
`net.ipv4.ip_unprivileged_port_start=0` inside the container), and the
apk package already ships `/run/nginx` and `/var/lib/nginx/tmp` owned by
`nginx`, so nothing else needs adjusting. nginx logs one warning that
`user nginx;` is ignored — expected, a non-root master can't switch
users. Ported from the [angie image](https://github.com/vdementev/angie);
its config/socket watchdogs were deliberately left out, since this image
bakes its config in and mounts no docker socket.

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

Security headers live in `/etc/nginx/security-headers.conf` and are
`include`d, not inherited: `add_header` does **not** merge across
config levels, so any `location` that sets a header of its own (the
cache-control ones do) drops everything inherited from `server`. Add
the same `include` to every location you give its own headers.

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

## Tests

`./tests.sh` builds the image, layers a fixture SPA on top and asserts
the behaviour this image promises: SPA fallback, cache headers,
security headers on every response type, `.br`/`.zst`/`.gz` sibling
selection, runtime gzip, `:8080` healthz/stub_status, and rootless
mode. CI runs the same script against the built image before anything
is published (`IMAGE=… ./tests.sh` to test an image you already have).

## CI

`.github/workflows/ci.yml` calls the shared reusable workflow in
[vdementev/docker-workflows](https://github.com/vdementev/docker-workflows).
A PR builds `linux/amd64` + `linux/arm64`, runs `tests.sh` and a Trivy
gate (fails on fixable CRITICAL/HIGH) without publishing; merging to
`main` publishes to Docker Hub as `dementev/nginx:latest` with SBOM,
max-mode provenance and Cosign keyless signing. A weekly cron rebuilds
to pick up package updates, and Renovate auto-merges base-image digest
and patch refreshes.

## Versioning

Tracks Alpine's nginx package. Deliberately unpinned: Alpine's branch
index only ever carries the newest `-rN`, so a pinned `nginx=1.30.4-r1`
would break the weekly rebuild the moment Alpine publishes `-r2`. To
pin a specific version, do it in a downstream Dockerfile where you
control the rebuild cadence:

```dockerfile
FROM alpine:3.24
RUN apk add nginx=1.30.4-r1 nginx-mod-http-brotli nginx-mod-http-zstd
```
