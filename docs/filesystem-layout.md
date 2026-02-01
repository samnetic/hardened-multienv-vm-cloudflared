# Filesystem Layout Guide

Where to put your infrastructure files according to Linux FHS (Filesystem Hierarchy Standard).

## TL;DR - Recommended Structure

```
/opt/hosting-blueprint/    # Template (setup scripts, docs)
/srv/infrastructure/       # Your infrastructure code
/srv/apps/                 # Your running applications
/var/secrets/              # Encrypted secrets
```

## Linux Filesystem Hierarchy Standard (FHS)

### `/opt` - Optional Software Packages
**Purpose:** Third-party, self-contained software packages

**Use for:**
- Pre-packaged applications
- Setup tools
- Template repositories

**Example:**
```
/opt/hosting-blueprint/    # Our template repo
/opt/cloudflare/           # Cloudflare packages
```

### `/srv` - Data Served by System
**Purpose:** Site-specific data served by this system

**Use for:**
- Web applications
- Infrastructure code
- Service configurations
- Static files served to users

**Example:**
```
/srv/infrastructure/       # Infrastructure as code
/srv/apps/                 # Application deployments
/srv/static/              # Static file hosting
```

### `/var` - Variable Data
**Purpose:** Variable data files (logs, databases, temporary files)

**Use for:**
- Logs
- Secrets (encrypted)
- Database files
- Docker volumes
- Caches

**Example:**
```
/var/secrets/             # Application secrets
/var/log/                 # System and app logs
/var/lib/docker/          # Docker volumes (automatic)
```

## Recommended Layout

### Complete Directory Tree

```
/opt/
└── hosting-blueprint/              # Template repository
    ├── scripts/                    # Setup & maintenance scripts
    │   ├── setup-vm.sh
    │   ├── install-cloudflared.sh
    │   ├── update-caddy.sh
    │   ├── prepare-ssh-keys.sh     # Run on local machine
    │   └── check-dns-exposure.sh
    ├── docs/                       # Documentation
    │   ├── 00-initial-setup.md
    │   ├── caddy-configuration-guide.md
    │   └── ...
    ├── infra/                      # Template configs (copy from)
    └── apps/                       # Template apps (copy from)

/srv/
├── infrastructure/                 # Infrastructure as Code (git repo)
│   ├── reverse-proxy/
│   │   ├── Caddyfile              # Main Caddy config
│   │   ├── compose.yml
│   │   ├── backups/               # Auto-created by update-caddy.sh
│   │   └── logs/                  # Caddy access logs
│   ├── monitoring/
│   │   └── netdata/
│   │       └── compose.yml
│   ├── .github/
│   │   └── workflows/             # CI/CD pipelines
│   │       └── deploy.yml
│   ├── .gitignore
│   └── README.md
│
├── apps/                          # Application deployments
│   ├── myapp-dev/
│   │   ├── compose.yml
│   │   ├── .env                   # Environment variables
│   │   ├── Dockerfile
│   │   └── src/
│   ├── myapp-staging/
│   └── myapp-production/
│
└── static/                        # Static file hosting (if needed)
    ├── images/
    ├── css/
    └── js/

/var/
├── secrets/                       # Secrets (NOT in git)
│   ├── dev/
│   │   ├── db_password
│   │   └── api_key
│   ├── staging/
│   └── production/
│
└── lib/docker/                    # Docker data (automatic)
    ├── volumes/                   # Named volumes
    ├── containers/
    └── overlay2/

/home/
└── sysadmin/
    ├── .ssh/                      # SSH keys
    └── .cloudflared/              # Cloudflare tunnel creds
```

## Setup Instructions

### Initial Setup (On VM)

```bash
# 1. Create directory structure
sudo mkdir -p /srv/infrastructure /srv/apps /srv/static /var/secrets/{dev,staging,production}
sudo chown -R sysadmin:sysadmin /srv /var/secrets

# 2. Copy templates from hosting-blueprint
cp -r /opt/hosting-blueprint/infra/* /srv/infrastructure/
cp -r /opt/hosting-blueprint/apps/* /srv/apps/

# 3. Configure for your domain
cd /srv/infrastructure/reverse-proxy
sed -i 's/yourdomain.com/example.com/g' Caddyfile  # Replace with YOUR domain

# 4. Initialize git repository
cd /srv/infrastructure
git init
git add .
git commit -m "Initial infrastructure setup"

# Optional: Push to GitHub
gh repo create myproject-infrastructure --private
git remote add origin https://github.com/YOUR_USERNAME/myproject-infrastructure.git
git push -u origin main

# 5. Start Caddy
cd /srv/infrastructure/reverse-proxy
docker compose up -d
```

## Daily Workflows

### Edit Caddy Configuration

```bash
# 1. Edit Caddyfile
vim /srv/infrastructure/reverse-proxy/Caddyfile

# 2. Validate and reload (zero downtime)
sudo /opt/hosting-blueprint/scripts/update-caddy.sh
# Auto-detects /srv/infrastructure/reverse-proxy

# 3. Commit changes
cd /srv/infrastructure
git add reverse-proxy/Caddyfile
git commit -m "Update Caddy config for new app"
git push
```

### Deploy New Application

```bash
# 1. Create app from template
cd /srv/apps
cp -r /opt/hosting-blueprint/apps/_template myapp-production

# 2. Configure app
cd myapp-production
vim compose.yml
vim .env

# 3. Start app
docker compose up -d

# 4. Add to Caddy
vim /srv/infrastructure/reverse-proxy/Caddyfile
sudo /opt/hosting-blueprint/scripts/update-caddy.sh

# 5. Add DNS CNAME in Cloudflare dashboard
```

### Create Secret

```bash
# Create secret file
/opt/hosting-blueprint/scripts/secrets/create-secret.sh production db_password

# Stored at: /var/secrets/production/db_password

# Reference in compose.yml:
# secrets:
#   db_password:
#     file: /var/secrets/production/db_password
```

## Alternative Layouts

### Option 1: Everything in `/srv` (Simplest)

```
/srv/
├── infrastructure/
├── apps/
└── secrets/           # Secrets here instead of /var
```

**Pros:** Everything in one place, simple permissions
**Cons:** Secrets not in standard /var location

### Option 2: Everything in `/opt` (Non-FHS)

```
/opt/
├── hosting-blueprint/
├── infrastructure/
└── apps/
```

**Pros:** Simple, all in one parent
**Cons:** Not FHS-compliant, /opt meant for packages

### Option 3: Split by Purpose (Most FHS-compliant)

```
/opt/hosting-blueprint/    # Setup scripts
/srv/infrastructure/       # Infrastructure code
/srv/apps/                 # Applications
/var/secrets/              # Secrets
/var/lib/docker/           # Docker data
```

**Pros:** Most standards-compliant
**Cons:** Slightly more complex
**Recommended:** ✅ Use this

## Permissions

### Recommended Ownership

```bash
# Template (read-only for reference)
/opt/hosting-blueprint/    → root:root (755)

# Infrastructure & apps (editable by sysadmin)
/srv/infrastructure/       → sysadmin:sysadmin (755)
/srv/apps/                 → sysadmin:sysadmin (755)

# Secrets (restricted)
/var/secrets/              → sysadmin:sysadmin (700)
/var/secrets/*/            → 600 (files), 700 (dirs)
```

### Set Permissions

```bash
# Setup scripts (read-only)
sudo chown -R root:root /opt/hosting-blueprint
sudo chmod -R 755 /opt/hosting-blueprint

# Infrastructure (editable)
sudo chown -R sysadmin:sysadmin /srv
sudo chmod -R 755 /srv

# Secrets (restricted)
sudo chown -R sysadmin:sysadmin /var/secrets
sudo chmod 700 /var/secrets
sudo find /var/secrets -type f -exec chmod 600 {} \;
sudo find /var/secrets -type d -exec chmod 700 {} \;
```

## Git Repositories

### `/opt/hosting-blueprint` - Upstream Template

```bash
cd /opt/hosting-blueprint
git pull origin master  # Get latest scripts and docs
```

- **Remote:** https://github.com/samnetic/hardened-multienv-vm
- **Purpose:** Template and tools
- **Workflow:** Pull-only (don't commit here)

### `/srv/infrastructure` - Your Infrastructure

```bash
cd /srv/infrastructure
git add .
git commit -m "Update configuration"
git push
```

- **Remote:** Your own repo (e.g., myproject-infrastructure)
- **Purpose:** Your infrastructure as code
- **Workflow:** Full git workflow (add, commit, push)

## Docker Volumes

Docker automatically uses `/var/lib/docker/volumes/` for named volumes:

```yaml
# In compose.yml
volumes:
  postgres_data:  # Stored at /var/lib/docker/volumes/postgres_data

# Or bind mount from /srv
volumes:
  - /srv/apps/myapp/uploads:/app/uploads
```

## Static File Serving

If serving static files via Caddy:

```bash
# Create static directory
sudo mkdir -p /srv/static/myapp
sudo chown -R sysadmin:sysadmin /srv/static

# In Caddyfile
http://static.yourdomain.com {
  root * /srv/static/myapp
  file_server
}
```

## Summary

**Recommended structure:**

| Path | Purpose | Git Tracked? | Who Edits? |
|------|---------|--------------|------------|
| `/opt/hosting-blueprint` | Setup scripts & docs | Template (pull-only) | Nobody (read-only) |
| `/srv/infrastructure` | Infrastructure code | Yes (your repo) | You |
| `/srv/apps` | Application deployments | Yes (your repo) | You |
| `/var/secrets` | Encrypted secrets | **No** (gitignored) | You (restricted) |
| `/var/lib/docker` | Docker data | No (automatic) | Docker |

**Quick Commands:**

```bash
# Update template scripts
cd /opt/hosting-blueprint && git pull

# Edit infrastructure
cd /srv/infrastructure
vim reverse-proxy/Caddyfile
sudo /opt/hosting-blueprint/scripts/update-caddy.sh
git add . && git commit -m "Update" && git push

# Deploy app
cd /srv/apps/myapp
docker compose up -d
```

This structure follows Linux FHS while being practical for infrastructure management.
