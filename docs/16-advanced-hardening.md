# Advanced Hardening (Optional)

This blueprint aims for a secure baseline with clean UX. If you want to push further (more “locked down”), use the options below. Each item has tradeoffs; apply in a maintenance window.

## Cloudflare Edge Hardening (Recommended)

Even with Tunnel-only origin access, the **edge** is your first and strongest control plane.

Baseline settings:
- SSL/TLS mode: **Full**
- Minimum TLS: **1.2**
- TLS 1.3: **On**
- Always Use HTTPS: **On**
- Automatic HTTPS Rewrites: **On**
- HSTS: **On** (include subdomains)

WAF and abuse controls:
- Enable **Managed WAF rules** (Cloudflare Free includes managed rulesets).
- Add **custom rules** to block common exploit paths:
  - `/.env`, `/.git`, `/wp-admin`, `/phpmyadmin`, etc.
- Add **rate limiting** for login and auth endpoints.
- Consider geo-fencing if your app is region-specific.
- Enable **Bot Fight Mode** (and AI bot blocking if available to you).

Defense-in-depth for Next.js:
- Strip internal middleware headers at the edge (Cloudflare Transform Rules) and/or at Caddy (this blueprint already strips common `x-middleware-*` headers in `infra/reverse-proxy/Caddyfile`).

## Cloudflare Access (SSO + Service Tokens)

Protect every “admin” hostname with SSO:
- `monitoring.<domain>`
- `n8n.<domain>`
- `pgadmin.<domain>`
- `minio.<domain>`

For machine-to-machine endpoints (CI, webhooks, internal APIs):
- Prefer **Service Tokens** (Access → Service Auth).
- If a webhook sender cannot attach headers, use a dedicated public hostname (e.g. `hooks.<domain>`) plus an app-level signature/secret.

See `docs/14-cloudflare-zero-trust.md`.

## Reduce Docker “Footguns”

The tunnel-only model is easy to accidentally break by publishing a container port.

This blueprint includes a detector:
- `scripts/security/check-docker-exposed-ports.sh`
- Installed to `/opt/scripts/check-docker-exposed-ports.sh` by `scripts/setup-vm.sh`
- Scheduled daily via `config/cron.d/vm-maintenance`

If it finds `0.0.0.0:` / `:::` published ports, treat that as a high severity misconfiguration.

## Mount `/tmp` as tmpfs with `noexec`

Hardening `/tmp` reduces common malware dropper techniques.

Enable via systemd (preferred over editing `/etc/fstab`):

```bash
sudo ./scripts/security/enable-tmpfs-tmp.sh
```

Disable/rollback:

```bash
sudo ./scripts/security/enable-tmpfs-tmp.sh --disable
```

Tradeoffs:
- Some installers and runtime tooling expect to execute from `/tmp`.
- tmpfs consumes RAM (and swap). The script defaults to 25% RAM capped at 2G.

## Stronger CI/CD Trust Model (Best ROI for “Extreme” Security)

If you want “extremely secure”, focus here:

- Treat CI deploy credentials as **high privilege**.
- Use GitHub Environments:
  - Require reviewers for `production`
  - Restrict who can trigger production deploys
- Prefer short-lived auth where possible:
  - Cloudflare Access for SSH (SSO) for humans
  - Cloudflare Service Tokens for CI

This blueprint already implements a stronger model by default:
- `appmgr` is **not** in the docker group.
- `appmgr` is restricted via `sshd ForceCommand` to `hosting ...` commands only.
- Deployments run through a root-owned tool (`hosting-deploy`) with compose policy checks.

Optional extra hardening:
- After tunnel migration, restrict sshd to loopback only (`ListenAddress 127.0.0.1` and `::1`) and/or add `from="127.0.0.1,::1"` to `authorized_keys`.
- Replace long-lived SSH keys with short-lived SSH certs (Cloudflare Access SSH cert flow).

### Deploy Policy Overrides (If Needed)

The deploy tool (`/usr/local/sbin/hosting-deploy`) is intentionally strict by default
to preserve the tunnel-only threat model.

If you have a legitimate need for exceptions, create a root-owned policy file:

```bash
sudo install -d -m 0755 /etc/hosting-blueprint
sudo nano /etc/hosting-blueprint/deploy-policy.env
```

Supported keys:
- `ALLOW_ANY_PORTS=1` (still denies public binds; see also `ALLOW_LOOPBACK_PORTS=1`)
- `ALLOW_LOOPBACK_PORTS=1`
- `ALLOW_BIND_PREFIXES=/var/secrets,/srv/static,/some/other/path`
- `ALLOW_CAP_ADD=NET_ADMIN` (exception list for otherwise-denied high-risk caps; avoid if possible)
- `ALLOW_BUILD=1` (allow `build:` in compose; prefer CI-built images instead)
- `DENY_LATEST_TAGS=1`
- `REQUIRE_RESOURCE_LIMITS=1` (fail deploys when services lack CPU/memory limits; pids limits still warned)

Keep this file off git and treat it as production config.

## Monitoring VPS Separation (Recommended)

Monitoring stacks often need elevated visibility (host mounts, docker socket, extra caps).

For a tighter blast radius:
- Run monitoring on a **separate VPS**
- Protect it with Cloudflare Access (SSO)
- Monitor the application VPS via:
  - HTTPS endpoints
  - SSH through Access (if needed)
  - Agent-based telemetry (only if you accept the extra footprint)
