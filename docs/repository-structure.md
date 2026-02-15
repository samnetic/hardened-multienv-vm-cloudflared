# Repository Structure (Recommended)

This blueprint is designed for a clean separation between:

- **Template**: `/opt/hosting-blueprint` (this repo, used for setup + scripts)
- **Infrastructure**: `/srv/infrastructure` (reverse proxy, monitoring, infra config)
- **Deployments**: `/srv/apps/{dev,staging,production}` (compose files for apps)
- **Secrets**: `/var/secrets/{dev,staging,production}` (never in git)

## Why This Matters

- Keeps **secrets out of git** by default.
- Makes it easy to **rebuild** a VPS: bootstrap, clone infra, deploy apps.
- Enables **GitOps**: infrastructure changes and app deployments have clear owners.

## What Goes Where

### `/opt/hosting-blueprint` (Template Repo)

- Setup scripts (`setup.sh`, `scripts/`)
- Reference templates (`infra/`, `apps/`)
- Documentation (`docs/`)

You can update it with `git pull` without touching running services (running services live in `/srv`).

### `/srv/infrastructure` (Infra Repo)

Git-tracked:

- `reverse-proxy/` (Caddyfile + compose)
- `monitoring/` (optional)
- `monitoring-agent/` (optional exporters for app VPS)
- `monitoring-server/` (optional Prometheus + Grafana + alerting for a separate monitoring VPS)
- `cloudflared/` (reference config only, not credentials)

Do not store credentials here. Keep it safe to push to a private Git repo.

### `/srv/apps/{dev,staging,production}` (Deployments Checkout)

Each environment directory is a deployment checkout (often a single "deployments repo") containing one or more apps:

```
/srv/apps/production/
  api/
    compose.yml
  n8n/
    compose.yml
```

GitHub Actions syncs your deployments repo to `/srv/apps/<env>` and triggers a guarded deploy via `hosting deploy <env>`, which runs `docker compose --compatibility up -d` per app directory with policy checks.

### `/var/secrets/{dev,staging,production}` (Secrets)

File-based secrets, owned by `root:hosting-secrets`, with strict permissions.

Apps mount secrets to `/run/secrets/*` (read-only).

## Industry-Standard Enhancements

- Pin server SSH host keys in CI (`SSH_KNOWN_HOSTS`) to prevent MITM.
- Use Cloudflare Access policies (SSO) for all admin panels.
- Use Cloudflare Access Service Tokens for CI and machine-to-machine webhooks.
- Optionally use encrypted `.env.*.enc` with SOPS/age (supported by `.gitignore` patterns).
