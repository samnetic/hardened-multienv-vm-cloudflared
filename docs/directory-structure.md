# Directory Structure Guide

Keep the "installer/template" separate from your "running infrastructure" and "running apps". This keeps updates clean and avoids mixing secrets into git.

## Recommended Structure

```
/opt/hosting-blueprint/        # This repo: installer scripts + templates (pull updates here)
/srv/infrastructure/           # Your infrastructure code (Caddy/monitoring config you own)
/srv/apps/                     # Your app deployments (per environment)
/var/secrets/                  # Host secrets (NOT in git)
```

## What Lives Where

### 1. `/opt/hosting-blueprint` (Template + Tools)

Purpose:
- One-time VM hardening and setup
- Reusable maintenance scripts
- Reference templates for infra/apps

Typical contents:
```
/opt/hosting-blueprint/
├── scripts/
├── docs/
├── infra/                     # Templates copied into /srv/infrastructure/
└── apps/                      # Templates copied into /srv/apps/ (optional)
```

Workflow:
- Update tooling: `cd /opt/hosting-blueprint && git pull`
- Do not store secrets here

### 2. `/srv/infrastructure` (Your Running Infra)

Purpose:
- Caddy reverse-proxy config and infra compose files you edit and version-control

Typical contents:
```
/srv/infrastructure/
├── reverse-proxy/
│   ├── Caddyfile
│   └── compose.yml
├── monitoring/
│   └── compose.yml
├── monitoring-agent/          # Optional: node-exporter + dockerd metrics proxy (app VPS)
│   ├── compose.yml
│   └── compose.cadvisor.yml   # Optional: per-container metrics (higher privilege)
├── monitoring-server/         # Optional: Prometheus + Grafana + Alertmanager (separate VPS)
│   └── compose.yml
└── cloudflared/               # Optional: tunnel config templates/docs
```

Workflow:
- This is yours. Commit/push changes in your infra repo.

### 3. `/srv/apps` (Your App Deployments)

Purpose:
- Compose stacks for apps, separated by environment tiers

Typical contents:
```
/srv/apps/
├── dev/
│   └── myapp/
│       ├── compose.yml
│       └── .env
├── staging/
│   └── myapp/
└── production/
    └── myapp/
```

### 4. `/var/secrets` (Host Secrets)

Purpose:
- File-based secrets mounted into containers at `/run/secrets/*`

Layout:
```
/var/secrets/
├── dev/
├── staging/
└── production/
```

Permissions (recommended):
- `/var/secrets` and env dirs: `root:hosting-secrets` `750`
- secret files: `root:hosting-secrets` `640`

## Initial Setup (Clean UX)

1. Install and harden the VM:
```bash
cd /opt/hosting-blueprint
sudo ./setup.sh
```

2. Initialize `/srv/infrastructure` from templates:
```bash
sudo ./scripts/setup-infrastructure-repo.sh yourdomain.com
```

3. Create Docker networks:
```bash
sudo ./scripts/create-networks.sh
```

4. Start the reverse proxy:
```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose --compatibility up -d
```

5. Create secrets (stored in `/var/secrets`):
```bash
./scripts/secrets/create-secret.sh staging db_password
./scripts/secrets/create-secret.sh production api_key
```

## Common Maintenance

Update Caddy safely:
```bash
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
```

Check DNS exposure (ensure no A/AAAA records point to your VM):
```bash
sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh yourdomain.com
```
