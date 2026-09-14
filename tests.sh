#!/usr/bin/env bash
# Smoke tests for the nginx base image.
#
#   ./tests.sh                 # builds the image from this repo, then tests it
#   IMAGE=some/nginx ./tests.sh  # tests an already-built image (this is how CI
#                                # calls it, via the reusable workflow's
#                                # test-command input)
set -euo pipefail

IMAGE="${IMAGE:-}"
FIXTURE=docker-nginx-test-fixture
CONTAINER=docker-nginx-test

pass=0; fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
tmp="$(mktemp -d)"
trap cleanup EXIT

# ── Build ───────────────────────────────────────────────────────
if [ -z "$IMAGE" ]; then
  info "Building image"
  docker build -q -t docker-nginx-test-base . >/dev/null
  IMAGE=docker-nginx-test-base
fi
echo "Testing image: $IMAGE"

# ── Fixture: a minimal SPA build output ─────────────────────────
mkdir -p "$tmp/app/assets"
printf '<!doctype html><title>fixture</title><div id=app></div>\n' > "$tmp/app/index.html"
printf 'BROTLI-SIBLING-PLACEHOLDER\n' > "$tmp/app/assets/app.js"
printf 'SECRET\n'    > "$tmp/app/.env"
printf '<svg/>\n'    > "$tmp/app/logo.svg"
# 1 KiB of compressible text, so gzip_min_length (400) is exceeded.
head -c 1024 /dev/zero | tr '\0' 'a' > "$tmp/app/big.css"

cat > "$tmp/Dockerfile" <<DOCKERFILE
FROM $IMAGE
COPY app/ /app/
# Pre-compressed siblings, the thing *_static actually serves. Built in the
# image so we don't need br/zstd/gzip CLIs on the test host.
RUN apk add --no-cache brotli zstd gzip \
 && brotli -k -f /app/assets/app.js \
 && zstd -q -k -f /app/assets/app.js \
 && gzip  -k -f /app/assets/app.js \
 && apk del brotli zstd gzip
DOCKERFILE

info "Building fixture"
docker build -q -t "$FIXTURE" "$tmp" >/dev/null

# ── Run ─────────────────────────────────────────────────────────
# Ephemeral host ports: a fixed pair collides with whatever else the machine
# (or a parallel CI job) happens to be running.
start() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" "$@" \
    -p 127.0.0.1::80 -p 127.0.0.1::8080 "$FIXTURE" >/dev/null
  base="http://$(docker port "$CONTAINER" 80/tcp | head -1)"
  metrics="http://$(docker port "$CONTAINER" 8080/tcp | head -1)"
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)" = healthy ] && break
    sleep 1
  done
}

start

# get <url> [curl args...] -> "<status>\n<headers>\n\n<body>"
get() { local url="$1"; shift; curl -sS -i --max-time 5 "$@" "$url"; }
status() { curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
header() { get "$1" "${@:3}" | tr -d '\r' | awk -v h="$2" 'BEGIN{IGNORECASE=1} $0 ~ "^"h":" {sub("^[^:]*: *",""); print}'; }

check_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
check_match() { # name pattern actual
  if printf '%s' "$3" | grep -Eqi -- "$2"; then ok "$1"; else bad "$1 (expected to match '$2', got '$3')"; fi
}

# ── Container health ────────────────────────────────────────────
info "Container"
check_eq "healthcheck reports healthy" healthy \
  "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")"
check_match "nginx 1.30 or newer" 'nginx/1\.(3[0-9]|[4-9][0-9])\.' \
  "$(docker run --rm "$IMAGE" nginx -v 2>&1)"
check_match "alpine is a tagged stable release, not edge" '^3\.[0-9]+\.[0-9]+$' \
  "$(docker run --rm "$IMAGE" cat /etc/alpine-release)"
check_eq "brotli + zstd modules present" 4 \
  "$(docker run --rm "$IMAGE" sh -c 'ls /usr/lib/nginx/modules | grep -c "brotli\|zstd"')"
check_eq "config parses" 0 \
  "$(docker run --rm "$IMAGE" nginx -t >/dev/null 2>&1; echo $?)"
check_match "workers run as nginx, not root" 'nginx' \
  "$(docker exec "$CONTAINER" sh -c "ps -o user,args | grep 'worker process' | grep -v grep | head -1")"

# ── SPA behaviour ───────────────────────────────────────────────
info "SPA routing"
check_eq "/ serves 200" 200 "$(status "$base/")"
check_eq "deep link falls back to index.html" 200 "$(status "$base/some/client/route")"
check_match "fallback body is index.html" 'id=app' "$(curl -sS --max-time 5 "$base/deep/link")"
check_eq "missing asset under /assets/ is a 404, not the SPA shell" 404 \
  "$(status "$base/assets/nope.js")"

# ── Caching ─────────────────────────────────────────────────────
info "Cache headers"
check_match "/assets/ immutable" 'immutable' "$(header "$base/assets/app.js" Cache-Control)"
check_match "/assets/ max-age 1y" '31536000' "$(header "$base/assets/app.js" Cache-Control)"
check_match "static asset 7d" '604800' "$(header "$base/logo.svg" Cache-Control)"
check_match "index.html no-store" 'no-store' "$(header "$base/index.html" Cache-Control)"

# ── Security headers ────────────────────────────────────────────
info "Security headers"
for path in / /index.html /assets/app.js /logo.svg; do
  check_match "X-Content-Type-Options on $path" 'nosniff' \
    "$(header "$base$path" X-Content-Type-Options)"
  check_match "Strict-Transport-Security on $path" 'max-age=63072000' \
    "$(header "$base$path" Strict-Transport-Security)"
done
check_eq "Server header is version-less" "nginx" "$(header "$base/" Server)"
check_eq "dotfiles are blocked" 403 "$(status "$base/.env")"

# ── Compression ─────────────────────────────────────────────────
info "Compression"
check_match "brotli sibling served for Accept-Encoding: br" '^br$' \
  "$(header "$base/assets/app.js" Content-Encoding -H 'Accept-Encoding: br')"
check_match "zstd sibling served for Accept-Encoding: zstd" '^zstd$' \
  "$(header "$base/assets/app.js" Content-Encoding -H 'Accept-Encoding: zstd')"
check_match "gzip sibling served for Accept-Encoding: gzip" '^gzip$' \
  "$(header "$base/assets/app.js" Content-Encoding -H 'Accept-Encoding: gzip')"
check_match "runtime gzip for a file with no sibling" '^gzip$' \
  "$(header "$base/big.css" Content-Encoding -H 'Accept-Encoding: gzip')"
check_eq "no compression when the client asks for none" "" \
  "$(header "$base/big.css" Content-Encoding -H 'Accept-Encoding: identity')"

# ── Metrics server ──────────────────────────────────────────────
info "Metrics server (:8080)"
check_eq "/healthz returns 200" 200 "$(status "$metrics/healthz")"
check_match "/stub_status exposes counters" 'Active connections' \
  "$(curl -sS --max-time 5 "$metrics/stub_status")"
check_eq "unknown path on :8080 is 404" 404 "$(status "$metrics/")"
check_eq "/ping is reachable on :80" 200 "$(status "$base/ping")"
check_eq "/ping sends exactly one Content-Type" 1 \
  "$(get "$base/ping" | tr -d '\r' | grep -ci '^content-type:')"
# Doubles as a real_ip test: the stub_status ACL matches on the address
# real_ip resolved to, so a forwarded public client is denied even though
# the TCP peer is private.
check_eq "/stub_status denies a forwarded public client" 403 \
  "$(status "$metrics/stub_status" -H 'X-Forwarded-For: 8.8.8.8')"
check_match "/ping answers pong" 'pong' \
  "$(docker exec "$CONTAINER" wget -qO- http://127.0.0.1/ping)"

# ── Rootless mode ───────────────────────────────────────────────
info "NGINX_DROP_MASTER=true"
start -e NGINX_DROP_MASTER=true
check_eq "container is healthy with a non-root master" healthy \
  "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")"
check_eq "still serves the site" 200 "$(status "$base/")"
check_match "master process runs as nginx" '^nginx' \
  "$(docker exec "$CONTAINER" sh -c "ps -o user,args | grep 'master process' | grep -v grep | head -1" | awk '{print $1}')"
# Also covers the buffered access_log (flush=5s) actually flushing, and the
# entrypoint's fd chown — a non-root master that can't reopen /dev/stdout
# logs nothing at all.
logs=""
for _ in $(seq 1 12); do
  logs="$(docker logs "$CONTAINER" 2>&1 | tail -40)"
  printf '%s' "$logs" | grep -q 'GET /' && break
  sleep 1
done
check_match "access log reached stdout as a non-root master" 'GET /' "$logs"

# ── Result ──────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
