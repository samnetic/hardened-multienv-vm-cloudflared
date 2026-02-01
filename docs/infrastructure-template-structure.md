# Infrastructure Template Repository Structure

This document describes the file structure for the GitHub template repository.

## Directory Tree

```
infrastructure/
├── .deploy/
│   ├── init-infrastructure.sh         # Run once after cloning to server
│   └── deploy-app.sh                  # Helper for custom app deployment
│
├── infra/
│   ├── reverse-proxy/
│   │   ├── docker-compose.yml
│   │   ├── Caddyfile                  # Main routing configuration
│   │   ├── .env.example
│   │   └── README.md
│   │
│   ├── monitoring/
│   │   ├── docker-compose.yml         # Grafana + Prometheus stack
│   │   ├── grafana/
│   │   │   └── provisioning/
│   │   ├── prometheus/
│   │   │   └── prometheus.yml
│   │   └── README.md
│   │
│   └── cloudflared/
│       ├── config.yml.example
│       └── README.md                  # Reference only (managed by sysadmin)
│
├── apps/
│   ├── n8n/
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── README.md
│   │
│   ├── portainer/
│   │   ├── docker-compose.yml
│   │   └── README.md
│   │
│   ├── nocodb/
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── README.md
│   │
│   └── grafana/
│       ├── docker-compose.yml
│       ├── .env.example
│       └── README.md
│
├── docs/
│   ├── 01-getting-started.md
│   ├── 02-deploy-third-party-app.md
│   ├── 03-deploy-custom-app.md
│   ├── 04-add-new-route.md
│   └── 05-troubleshooting.md
│
├── .github/
│   └── workflows/
│       └── deploy-infrastructure.yml  # GitOps for infrastructure changes
│
├── .gitignore
├── README.md
└── LICENSE
```

## File Contents

### `.deploy/init-infrastructure.sh`

See `scripts/init-infrastructure.sh` in this repo.

### `infra/reverse-proxy/Caddyfile`

```caddyfile
# =================================================================
# Caddy Reverse Proxy Configuration
# =================================================================
# This file defines all routing for your domain
#
# Pattern: http://subdomain.{$DOMAIN} { reverse_proxy container:port }
#
# After editing, reload: docker compose restart
# =================================================================

# Third-party apps
http://n8n.{$DOMAIN} {
    reverse_proxy n8n-prod:5678
}

http://portainer.{$DOMAIN} {
    reverse_proxy portainer-prod:9000
}

http://nocodb.{$DOMAIN} {
    reverse_proxy nocodb-prod:8080
}

http://grafana.{$DOMAIN} {
    reverse_proxy grafana-monitoring:3000
}

# Custom apps (add your routes here)
# http://api.{$DOMAIN} {
#     reverse_proxy my-api-prod:3000
# }

# http://app.{$DOMAIN} {
#     reverse_proxy my-nextjs-app-prod:3000
# }

# Staging environment
http://staging-n8n.{$DOMAIN} {
    reverse_proxy n8n-staging:5678
}

# Development environment
http://dev-n8n.{$DOMAIN} {
    reverse_proxy n8n-dev:5678
}

# Catch-all for undefined routes (optional)
http://*.{$DOMAIN} {
    respond "Service not configured" 404
}
```

### `infra/reverse-proxy/docker-compose.yml`

```yaml
version: '3.8'

services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - dev-web
      - staging-web
      - prod-web
      - monitoring
    environment:
      - DOMAIN=${DOMAIN}
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:80"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  caddy_data:
  caddy_config:

networks:
  dev-web:
    external: true
  staging-web:
    external: true
  prod-web:
    external: true
  monitoring:
    external: true
```

### `infra/reverse-proxy/.env.example`

```bash
# Domain name (without http://)
DOMAIN=yourdomain.com
```

### `apps/n8n/docker-compose.yml`

```yaml
version: '3.8'

services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-prod
    restart: unless-stopped
    networks:
      - prod-web
      - prod-db
    environment:
      - N8N_HOST=n8n.${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - NODE_ENV=production
      - WEBHOOK_URL=https://n8n.${DOMAIN}
      - GENERIC_TIMEZONE=${TIMEZONE:-UTC}
    volumes:
      - n8n_data:/home/node/.n8n
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  n8n_data:

networks:
  prod-web:
    external: true
  prod-db:
    external: true
```

### `apps/n8n/.env.example`

```bash
DOMAIN=yourdomain.com
TIMEZONE=UTC
```

### `apps/portainer/docker-compose.yml`

```yaml
version: '3.8'

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer-prod
    restart: unless-stopped
    networks:
      - prod-web
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    command: --no-analytics
    security_opt:
      - no-new-privileges:true

volumes:
  portainer_data:

networks:
  prod-web:
    external: true
```

### `README.md`

```markdown
# Infrastructure Repository

This repository contains all infrastructure configuration for your server.

## Quick Start

### 1. Clone to Server

```bash
# SSH to server
ssh codeagen

# Switch to appmgr
sudo su - appmgr

# Clone repository
git clone https://github.com/YOUR_ORG/infrastructure.git /opt/infrastructure
cd /opt/infrastructure
```

### 2. Initialize

```bash
./.deploy/init-infrastructure.sh
```

This creates Docker networks, directories, and starts Caddy.

### 3. Deploy Third-Party Apps

```bash
# n8n
cd apps/n8n
cp .env.example .env
nano .env  # Set DOMAIN
docker compose up -d

# Portainer
cd apps/portainer
docker compose up -d
```

### 4. Update Routing

Edit `infra/reverse-proxy/Caddyfile` to add routes.

Reload Caddy:
```bash
cd infra/reverse-proxy
docker compose restart
```

## Structure

- `infra/` - Core infrastructure (reverse proxy, monitoring)
- `apps/` - Third-party applications (n8n, Portainer, etc.)
- `.deploy/` - Deployment scripts
- `docs/` - Documentation

## Documentation

- [Getting Started](docs/01-getting-started.md)
- [Deploy Third-Party App](docs/02-deploy-third-party-app.md)
- [Deploy Custom App](docs/03-deploy-custom-app.md)
- [Add New Route](docs/04-add-new-route.md)
- [Troubleshooting](docs/05-troubleshooting.md)

## Custom Applications

Custom applications (APIs, NextJS apps) should be in separate repositories.

See [docs/03-deploy-custom-app.md](docs/03-deploy-custom-app.md) for integration pattern.
```

### `.gitignore`

```gitignore
# Environment files
.env
*.env
!.env.example

# Secrets
secrets/
*.key
*.pem
*.crt

# Docker volumes (data managed outside git)
**/data/
**/volumes/

# Logs
*.log

# OS files
.DS_Store
Thumbs.db

# Editor files
.vscode/
.idea/
*.swp
*.swo

# Temporary files
tmp/
temp/
```

## Usage

### Create GitHub Template

1. Create new repository on GitHub named `infrastructure-template`
2. Add all files from the structure above
3. Go to Settings → Template repository → Check "Template repository"

### Use Template

1. Click "Use this template" → Create new repository
2. Clone to server: `git clone https://github.com/YOUR_ORG/infrastructure.git /opt/infrastructure`
3. Run initialization: `cd /opt/infrastructure && ./.deploy/init-infrastructure.sh`

### Update Infrastructure

```bash
# Make changes
nano infra/reverse-proxy/Caddyfile

# Commit and push
git add .
git commit -m "Add route for new API"
git push

# On server, pull changes
ssh codeagen
sudo su - appmgr
cd /opt/infrastructure
git pull
cd infra/reverse-proxy
docker compose restart
```

## Benefits

✅ **Version controlled** - All infrastructure changes tracked in git
✅ **Reproducible** - Can recreate entire server from this repo
✅ **Documented** - Each app has README with setup instructions
✅ **Secure** - Secrets in .env (not committed), proper permissions
✅ **Maintainable** - Clear structure, easy to understand
✅ **Scalable** - Add new apps without touching core infrastructure
