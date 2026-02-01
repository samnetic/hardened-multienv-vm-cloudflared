# Repository Structure Guide

## Overview

This guide explains the recommended repository structure for hosting applications on your hardened VM.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Infrastructure Monorepo (GitHub Template)                   │
│ /opt/infrastructure/                                         │
│                                                              │
│ ├── infra/                                                   │
│ │   ├── reverse-proxy/      ← Caddyfile (all routing)      │
│ │   ├── monitoring/          ← Grafana, Prometheus          │
│ │   └── cloudflared/         ← Tunnel config (read-only)    │
│ │                                                              │
│ ├── apps/                                                    │
│ │   ├── n8n/                 ← Third-party: n8n             │
│ │   ├── portainer/           ← Third-party: Portainer       │
│ │   ├── nocodb/              ← Third-party: NocoDB          │
│ │   └── grafana/             ← Third-party: Grafana         │
│ │                                                              │
│ └── .deploy/                                                │
│     ├── init-infrastructure.sh  ← Run once after clone      │
│     └── deploy-app.sh           ← Deploy custom app repos   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Custom App Repos (Separate Repositories)                    │
│                                                              │
│ my-nextjs-app/           my-api/              my-dashboard/ │
│ ├── src/                 ├── src/             ├── src/      │
│ ├── docker-compose.yml   ├── Dockerfile       ├── Dockerfile│
│ ├── Dockerfile           └── .deploy/         └── .deploy/  │
│ └── .github/workflows/       └── deploy.yml       └── deploy.yml
└─────────────────────────────────────────────────────────────┘
```

## Why This Structure?

### Infrastructure Monorepo
✅ **Single source of truth** for server configuration
✅ **Third-party apps** (n8n, Grafana) live here because they're environment config
✅ **Easy to backup** - one repo captures entire server state
✅ **Clear ownership** - appmgr user owns this repo

### Separate Custom App Repos
✅ **Independent versioning** - each app has its own release cycle
✅ **Clean CI/CD** - GitHub Actions deploys one app at a time
✅ **Team collaboration** - different teams can own different apps
✅ **Portable** - can run locally, different servers

## Setup Process

### 1. Create Infrastructure Monorepo from Template

Go to GitHub → Use Template:
```
https://github.com/YOUR_ORG/infrastructure-template
```

Click "Use this template" → Create new repository named `infrastructure`

### 2. Initialize on Server

```bash
# SSH to server
ssh codeagen

# Switch to appmgr user
sudo su - appmgr

# Clone infrastructure repo
git clone https://github.com/YOUR_ORG/infrastructure.git /opt/infrastructure
cd /opt/infrastructure

# Run initialization
./.deploy/init-infrastructure.sh
```

The init script:
- Sets proper permissions
- Creates Docker networks
- Starts reverse proxy (Caddy)
- Starts monitoring stack
- Verifies setup

### 3. Deploy Third-Party Apps

Each app has a `docker-compose.yml`:

```bash
cd /opt/infrastructure/apps/n8n
docker compose up -d
```

### 4. Deploy Custom Apps

From your **local machine**, push to GitHub → GitHub Actions deploys:

```yaml
# .github/workflows/deploy.yml in custom app repo
name: Deploy to Production

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Deploy via SSH
        env:
          SSH_KEY: ${{ secrets.APPMGR_SSH_KEY }}
        run: |
          # Install cloudflared
          curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
          chmod +x cloudflared

          # Setup SSH
          mkdir -p ~/.ssh
          echo "$SSH_KEY" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa

          # Deploy
          ssh -o ProxyCommand="./cloudflared access ssh --hostname ssh.codeagen.com" \
              -o StrictHostKeyChecking=no \
              appmgr@ssh.codeagen.com \
              "cd /srv/apps/production/my-app && git pull && docker compose up -d --build"
```

## Integration Pattern

### Infrastructure Monorepo Caddyfile

All routing lives in one place:

```caddyfile
# Third-party apps (from infrastructure monorepo)
http://n8n.codeagen.com {
    reverse_proxy n8n-prod:5678
}

http://portainer.codeagen.com {
    reverse_proxy portainer-prod:9000
}

# Custom apps (from separate repos)
http://api.codeagen.com {
    reverse_proxy my-api-prod:3000
}

http://app.codeagen.com {
    reverse_proxy my-nextjs-app-prod:3000
}
```

### Custom App docker-compose.yml

Custom apps connect to infrastructure networks:

```yaml
# /srv/apps/production/my-api/docker-compose.yml
version: '3.8'

services:
  api:
    container_name: my-api-prod
    build: .
    networks:
      - prod-web  # Connect to Caddy network
    environment:
      - NODE_ENV=production

networks:
  prod-web:
    external: true  # Created by infrastructure repo
```

## Workflow

### Day 1: Setup
```bash
1. Use GitHub template → create infrastructure repo
2. Clone to /opt/infrastructure on server
3. Run init-infrastructure.sh
4. Deploy third-party apps (n8n, Grafana, etc.)
5. Update Caddyfile with routes
6. Restart Caddy
```

### Day 2+: Deploy Custom App
```bash
1. Create new app repo (my-nextjs-app)
2. Add Dockerfile, docker-compose.yml
3. Add GitHub Actions workflow
4. Push to main → auto-deploys
5. Add route to infrastructure/infra/reverse-proxy/Caddyfile
6. Git commit + push infrastructure repo
7. SSH to server → pull infrastructure repo → restart Caddy
```

## Advantages

✅ **Simplest mental model**: Infrastructure vs Applications
✅ **Best UX**: One command to initialize, GitOps for updates
✅ **Secure**: appmgr owns everything, proper permissions
✅ **Scalable**: Add new apps without touching infrastructure
✅ **Maintainable**: Clear separation of concerns
✅ **Gitops-native**: Git is single source of truth

## File Permissions

```bash
/opt/infrastructure/           # appmgr:appmgr 755
/srv/apps/production/my-app/   # appmgr:appmgr 755
/etc/cloudflared/              # root:root 755 (managed by sysadmin)
```

## Next Steps

1. Create GitHub template repository
2. Add initialization script
3. Add example third-party app configs
4. Document custom app integration pattern
