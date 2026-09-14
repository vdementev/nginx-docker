#!/bin/sh
# Thin entrypoint. Does nothing at all unless NGINX_DROP_MASTER=true, so
# the default behaviour is byte-for-byte what `CMD nginx -g 'daemon off;'`
# did before: root master, `user nginx;` handles worker privilege
# separation, exactly like the stock nginx image.
#
# Deliberately NOT ported from the angie image: the config watchdog and
# the socket watchdog. Both exist there because angie mounts its config
# and the docker socket from the host; here the config is baked into the
# image and there is no socket, so a background poller would only add a
# process and wake-ups to an image whose whole point is being small.
set -eu

USER_NAME="${NGINX_USER:-nginx}"

warn() { printf '[entrypoint] %s\n' "$*" >&2; }

# ── Master process privilege ────────────────────────────────────
# Set NGINX_DROP_MASTER=true to run the master as NGINX_USER instead of
# root. Ports 80/8080 still bind — Docker sets
# net.ipv4.ip_unprivileged_port_start=0 inside the container — and the
# apk package already ships /run/nginx and /var/lib/nginx/tmp owned by
# nginx, so the pid file and the *_temp paths need no extra work. The
# `user nginx;` directive becomes a no-op (a non-root master can't switch
# users; nginx logs a warning and ignores it).
if [ "${NGINX_DROP_MASTER:-}" = "true" ] && [ "$USER_NAME" != "root" ]; then
  if ! getent passwd "$USER_NAME" >/dev/null 2>&1; then
    warn "NGINX_DROP_MASTER=true but user '$USER_NAME' does not exist; staying root"
  elif [ "$(id -u)" != "0" ]; then
    # Already non-root (compose `user:`), nothing to drop.
    exec "$@"
  else
    # Docker hands the container its stdout/stderr as root-owned 0600 pipes
    # and nginx *reopens* them by path (access_log /dev/stdout,
    # error_log /dev/stderr), so a non-root master dies at startup with
    # "Permission denied" before it can log why. Hand both over while we
    # still have the privilege to do it.
    # No `2>/dev/null` here, on purpose: the redirect would replace chown's
    # own fd 2, so /proc/self/fd/2 would resolve to /dev/null and the chown
    # would "succeed" against the wrong file.
    for fd in 1 2; do
      chown "$USER_NAME" "/proc/self/fd/$fd" \
        || warn "could not chown fd $fd to '$USER_NAME'; nginx may fail to open its logs"
    done

    exec su-exec "$USER_NAME" "$@"
  fi
fi

exec "$@"
