# Support and lifecycle

## Tags

| Tag | Contents |
|---|---|
| `latest` | The newest build. Moves on every merge to `main` and on the weekly rebuild. |
| `1.30.4` | The exact nginx version inside the image. Republished in place (new digest, same tag) while that version is current. |
| `1.30` | The newest patch release of that nginx minor. |

Version tags are read out of the image after it is built and tested, so a tag
can never claim a version the image does not actually run.

Architectures: `linux/amd64`, `linux/arm64`.

## What "supported" means

A tag is supported while it is being rebuilt. `latest` and the current version
tags are rebuilt weekly (Monday, ~03:25 UTC) so they pick up base-image and
package security updates without anyone filing a bump. Older version tags stay
pullable, but they are frozen: no rebuilds, no CVE fixes.

There is no long-term-support tag here. nginx moves fast in Alpine, and the
weekly rebuild is what keeps the image current; if you need a frozen artifact,
freeze it yourself by digest.

## Pinning

Pin the digest, not the tag:

```dockerfile
FROM dementev/nginx:1.30@sha256:...
```

That gives you a byte-identical base until you choose to move, while the tag in
front of it still tells you what it is. Renovate and Dependabot both understand
this form and will open a pull request when the digest changes.

## Patch cadence

| Trigger | What happens |
|---|---|
| Merge to `main` | Full build, tests, Trivy gate, publish, sign |
| Weekly cron | Same pipeline, no source change — picks up upstream package updates |
| Fixable CRITICAL/HIGH CVE | The build fails and nothing is published until it is fixed or explicitly accepted in `.trivyignore` |

## Breaking changes

Anything that changes the default served behaviour — the baked `nginx.conf`,
the ports, the entrypoint contract — is called out in the pull request and in
the release notes. Config changes land with a test in `tests.sh` covering the
new behaviour.

## Getting help

Open an issue at
[github.com/vdementev/nginx-docker/issues](https://github.com/vdementev/nginx-docker/issues).
Security reports go through [SECURITY.md](SECURITY.md) instead.
