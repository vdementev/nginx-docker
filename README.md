# nginx

Reusable nginx base image for static sites and SPAs, designed to live
**behind a reverse proxy** (HAProxy / Traefik / Angie / nginx) on a
docker network. TLS, HTTP/2, public-internet exposure are handled by
the proxy in front; this layer just serves files fast and cheap.

`FROM` it in your project's Dockerfile, drop your build output into
`/app`, and you're done.

## Tags

| Tag | Contents |
|---|---|
| `latest` | The newest build. |
| `1.30.4` | The exact nginx version inside the image. |
| `1.30` | The newest patch of that nginx minor. |

Version tags are read out of the image *after* it is built and tested, so a tag
can never claim a version the image does not run. `linux/amd64` and
`linux/arm64`. Lifecycle and pinning: [SUPPORT.md](SUPPORT.md).

## What's in the image

- **Alpine stable** (`alpine:latest`, currently 3.24) + **nginx 1.30.x**
  (apk-installed, follows Alpine's nginx track).
- **brotli** static module (`nginx-mod-http-brotli`).
- **zstd** static module (`nginx-mod-http-zstd`).
- **stub_status** on a separate metrics server (`:8080`) for
  `nginx-prometheus-exporter` scrape, with `/healthz` for liveness.
- `su-exec` + a 30-line entrypoint, for the optional rootless mode below.
- Every setuid/setgid bit stripped at build time (Alpine ships none today —
  it's a guard against a future package adding one), no logrotate wiring,
  and a `nginx -t` gate so a typo in the baked config fails the build.
- No `ca-certificates`, no `tzdata` — this nginx makes no outbound TLS
  calls and logs in UTC. Add either back in a downstream image if needed.

Alpine **stable**, not `edge`: edge happens to carry the same nginx
1.30.x, so tracking it bought nothing but the risk of a toolchain or
ABI change landing in the middle of a weekly rebuild. The stable branch
carries the same CVE backports on a predictable cadence.

Nothing is version-pinned or digest-pinned, on purpose. The weekly
rebuild picks up new base images and packages by itself, and no build
can publish without passing `tests.sh` and the Trivy gate first — so a
floating tag is caught by CI rather than by a deploy. Pin downstream if
you need a frozen artifact.

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
users. Ported from the [angie image](https://github.com/vdementev/angie-docker);
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
`main` publishes to Docker Hub as `dementev/nginx:latest` plus the version
tags derived from the built image, with SBOM, max-mode provenance and Cosign
keyless signing. A weekly cron rebuilds
to pick up base-image and package updates — which is also what keeps the
floating `alpine:latest` honest, since that rebuild runs the same tests
and scan.

## Versioning

The apk package is deliberately unpinned. Alpine's branch index only ever
carries the newest `-rN`, so a pinned `nginx=1.30.4-r1` would break the weekly
rebuild the moment Alpine publishes `-r2`. What you get instead is a version tag
derived from the built image and a weekly rebuild that has to pass `tests.sh`
and the Trivy gate before it can replace anything.

To pin a specific nginx build rather than a specific image, do it downstream
where you control the rebuild cadence:

```dockerfile
FROM alpine:3.24
RUN apk add nginx=1.30.4-r1 nginx-mod-http-brotli nginx-mod-http-zstd
```

To pin this image, pin its digest — every digest is Cosign-signed and carries an
SBOM:

```dockerfile
FROM dementev/nginx:1.30@sha256:...
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

[SECURITY.md](SECURITY.md) is the reporting channel and the response
targets; [SUPPORT.md](SUPPORT.md) covers tag lifecycle, pinning and
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

Packaging in this repository is MIT licensed — see [LICENSE](LICENSE). The software
inside the image keeps its own upstream licenses.
