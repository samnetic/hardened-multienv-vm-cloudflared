# Quick Start: Repository Setup

## TL;DR - Recommended Approach

**Use a hybrid approach:**
1. **Infrastructure Monorepo** (GitHub template) - for server config + third-party apps
2. **Separate Custom App Repos** - for your APIs, NextJS apps, etc.
3. **Initialization Script** - automates the setup

## Why This Approach?

✅ **Cleanest structure** - Clear separation between infrastructure and applications
✅ **Best UX** - One command to initialize, GitOps for updates
✅ **Easiest to maintain** - Infrastructure changes don't affect app deployments
✅ **Scalable** - Add new apps without touching core infrastructure

## Setup in 3 Steps

### Step 1: Create Infrastructure Template on GitHub

1. Create new repository: `infrastructure-template`
2. Copy structure from `docs/infrastructure-template-structure.md`
3. Mark as template repository (Settings → Template repository)

### Step 2: Use Template on Server

```bash
# SSH to server
ssh codeagen
sudo su - appmgr

# Clone your infrastructure repo
git clone https://github.com/YOUR_ORG/infrastructure.git /opt/infrastructure
cd /opt/infrastructure

# Run initialization
./.deploy/init-infrastructure.sh
```

This script:
- Creates Docker networks (dev, staging, prod)
- Creates `/srv/apps/` directories
- Starts Caddy reverse proxy
- Sets proper permissions

### Step 3: Deploy Apps

**Third-party apps (n8n, Grafana, etc.):**
```bash
cd /opt/infrastructure/apps/n8n
cp .env.example .env
nano .env  # Set DOMAIN
docker compose up -d
```

**Custom apps (your APIs, NextJS, etc.):**
```bash
cd /opt/infrastructure
./scripts/setup-custom-app.sh \
  --repo https://github.com/YOUR_ORG/my-api \
  --env production \
  --subdomain api
```

## Repository Structure

```
┌─────────────────────────────────────────────────────────┐
│ /opt/infrastructure/ (Monorepo - GitHub Template)      │
│                                                          │
│ ├── infra/                                              │
│ │   ├── reverse-proxy/   ← Caddyfile (all routing)    │
│ │   └── monitoring/      ← Grafana, Prometheus         │
│ │                                                          │
│ ├── apps/                                               │
│ │   ├── n8n/             ← Third-party apps            │
│ │   ├── portainer/                                      │
│ │   └── grafana/                                        │
│ │                                                          │
│ └── .deploy/                                            │
│     ├── init-infrastructure.sh                         │
│     └── setup-custom-app.sh                            │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ /srv/apps/{env}/ (Custom Apps - Separate Repos)        │
│                                                          │
│ ├── my-api/          ← Deployed from GitHub            │
│ ├── my-nextjs-app/   ← Deployed via CI/CD              │
│ └── my-dashboard/    ← Each has own repo                │
└─────────────────────────────────────────────────────────┘
```

## Routing (Caddyfile)

All routing lives in ONE place:

```caddyfile
# /opt/infrastructure/infra/reverse-proxy/Caddyfile

# Third-party apps
http://n8n.{$DOMAIN} {
    reverse_proxy n8n-prod:5678
}

# Custom apps
http://api.{$DOMAIN} {
    reverse_proxy my-api-prod:3000
}

http://app.{$DOMAIN} {
    reverse_proxy my-nextjs-app-prod:3000
}
```

After editing:
```bash
cd /opt/infrastructure/infra/reverse-proxy
docker compose restart
```

## Integration: Custom App → Infrastructure

Your custom app `docker-compose.yml` connects to infrastructure networks:

```yaml
# /srv/apps/production/my-api/docker-compose.yml
version: '3.8'

services:
  api:
    container_name: my-api-prod
    build: .
    networks:
      - prod-web  # Created by infrastructure
    restart: unless-stopped

networks:
  prod-web:
    external: true  # Managed by /opt/infrastructure
```

## Deployment Workflows

### Manual Deployment (Simple)

```bash
# Third-party app
cd /opt/infrastructure/apps/n8n
docker compose up -d

# Custom app
cd /srv/apps/production/my-api
git pull
docker compose up -d --build
```

### Automated GitOps (Recommended)

**For infrastructure changes:**
```bash
# Edit Caddyfile locally
git commit -m "Add route for new API"
git push

# On server
ssh codeagen
sudo su - appmgr
cd /opt/infrastructure
git pull
cd infra/reverse-proxy && docker compose restart
```

**For custom app deployments:**

Add to your custom app repo `.github/workflows/deploy.yml`:
```yaml
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

Push to `main` → auto-deploys!

## Comparison: Why Not Other Approaches?

### ❌ Shell Script Only
```bash
# Bad: Not version controlled, hard to update
./create-structure.sh
```

**Problems:**
- Changes aren't tracked
- Can't review history
- Hard to collaborate

### ❌ Monorepo for Everything
```bash
infrastructure/
├── apps/n8n/
├── apps/my-api/         # Bad: App code mixed with infra
├── apps/my-nextjs-app/  # Bad: Violates separation of concerns
```

**Problems:**
- Huge repo with mixed concerns
- App changes trigger infra CI/CD
- Can't have separate teams/permissions
- Hard to version apps independently

### ✅ Hybrid Approach (Recommended)
```bash
infrastructure/           # Template, one repo
├── infra/               # Server config
└── apps/n8n/            # Third-party config

my-api/                  # Separate repo per custom app
my-nextjs-app/           # Independent versioning
```

**Benefits:**
- Clear boundaries
- Independent versioning
- Proper separation of concerns
- Easy to understand

## SSL Certificates (Zero Manual Work)

✅ Cloudflare provisions FREE wildcard SSL automatically
✅ Covers `*.codeagen.com` - ALL subdomains
✅ Automatic renewal - NEVER expires
✅ No cert files to manage

Just add subdomain to Caddyfile → works with HTTPS!

## Permissions

Everything owned by `appmgr`:

```bash
/opt/infrastructure/          # appmgr:appmgr 755
/srv/apps/production/my-api/  # appmgr:appmgr 755
```

Cloudflared config stays with sysadmin:
```bash
/etc/cloudflared/             # root:root 755
```

## Next Steps

1. **Read detailed docs:**
   - `docs/infrastructure-template-structure.md` - Full template structure
   - `docs/repository-structure.md` - Architecture explanation

2. **Create your infrastructure template on GitHub**

3. **Initialize on server:**
   ```bash
   git clone YOUR_TEMPLATE /opt/infrastructure
   cd /opt/infrastructure
   ./.deploy/init-infrastructure.sh
   ```

4. **Deploy your first app:**
   ```bash
   ./scripts/setup-custom-app.sh --repo YOUR_REPO --env production --subdomain api
   ```

## Questions?

- Infrastructure setup issues? Check `docs/troubleshooting.md`
- App deployment issues? Check app logs: `docker compose logs -f`
- SSL not working? Verify Cloudflare DNS is proxied (orange cloud)
- Routing issues? Check Caddyfile syntax and restart Caddy

---

**You now have:**
✅ Infrastructure as code (version controlled)
✅ Automated setup (one command)
✅ Clean separation (infra vs apps)
✅ Easy deployment (GitOps ready)
✅ Scalable architecture (add apps easily)
✅ Secure by default (zero open ports, proper permissions)
