# Directory Structure Guide

Proper organization for template setup scripts vs. your running infrastructure.

## Two Separate Directories

### 1. `/opt/hosting-blueprint` - Template & Setup Scripts

**Purpose:** One-time setup, reference, and script updates

**Contents:**
```
/opt/hosting-blueprint/
├── scripts/              # Setup & maintenance scripts
│   ├── setup-vm.sh      # Initial VM hardening
│   ├── install-cloudflared.sh
│   ├── prepare-ssh-keys.sh (run on local machine)
│   ├── check-dns-exposure.sh
│   ├── update-caddy.sh   # Safe Caddy reload helper
│   └── init-gitops.sh    # GitHub CI/CD setup
├── docs/                 # Documentation
│   ├── 00-initial-setup.md
│   ├── caddy-configuration-guide.md
│   └── ...
├── infra/                # Template configs (copy from here)
├── apps/                 # Template apps (copy from here)
└── README.md
```

**Git workflow:**
- This is the upstream template repository
- Pull updates: `cd /opt/hosting-blueprint && git pull`
- Don't modify files here (they'll be overwritten on pull)
- Use as reference only

### 2. `/opt/infrastructure` - Your Running Services

**Purpose:** Your actual infrastructure (version controlled, deployed)

**Contents:**
```
/opt/infrastructure/
├── infra/
│   ├── reverse-proxy/
│   │   ├── Caddyfile          # ← Edit this for yourdomain.com
│   │   ├── compose.yml
│   │   ├── logs/
│   │   └── backups/           # Auto-created by update-caddy.sh
│   └── monitoring/
│       └── netdata/
│           └── compose.yml
├── apps/
│   ├── _template/             # Copy this for new apps
│   ├── myapp-dev/
│   │   ├── compose.yml
│   │   ├── .env
│   │   ├── Dockerfile
│   │   └── src/
│   ├── myapp-staging/
│   └── myapp-production/
├── secrets/
│   ├── dev/
│   ├── staging/
│   └── production/
├── .github/
│   └── workflows/
│       └── deploy.yml         # CI/CD pipeline
├── .gitignore
└── README.md                  # Your infrastructure docs
```

**Git workflow:**
- This is YOUR git repository
- Track changes: `git add`, `git commit`, `git push`
- Deploy via GitHub Actions
- Your team collaborates here

## Initial Setup Process

### Step 1: Clone Template (One-Time)

```bash
# Already done via bootstrap.sh
cd /opt/hosting-blueprint
git pull  # Get latest scripts and docs
```

### Step 2: Create Your Infrastructure Repo

```bash
# Create your infrastructure directory
sudo mkdir -p /opt/infrastructure
sudo chown $USER:$USER /opt/infrastructure

# Copy template structure
cp -r /opt/hosting-blueprint/infra /opt/infrastructure/
cp -r /opt/hosting-blueprint/apps /opt/infrastructure/
cp /opt/hosting-blueprint/.gitignore /opt/infrastructure/

# Initialize git
cd /opt/infrastructure
git init
git add .
git commit -m "Initial infrastructure setup"

# Create GitHub repo and push
gh repo create myproject-infrastructure --private
git remote add origin https://github.com/YOUR_USERNAME/myproject-infrastructure.git
git push -u origin main
```

### Step 3: Configure for Your Domain

```bash
cd /opt/infrastructure/infra/reverse-proxy

# Update domain
sed -i 's/yourdomain.com/example.com/g' Caddyfile  # Replace with YOUR domain

# Commit changes
git add Caddyfile
git commit -m "Configure domain"
git push
```

### Step 4: Start Services

```bash
cd /opt/infrastructure/infra/reverse-proxy
docker compose up -d

# Verify
docker compose ps
docker compose logs -f
```

## Using Setup Scripts from Template

Setup scripts in `/opt/hosting-blueprint/scripts/` can be run from anywhere.

### Update Caddy Configuration Safely

```bash
# Edit your infrastructure Caddyfile
vim /opt/infrastructure/infra/reverse-proxy/Caddyfile

# Use template script to validate and reload
sudo /opt/hosting-blueprint/scripts/update-caddy.sh \
  /opt/infrastructure/infra/reverse-proxy

# Or create a wrapper script
```

**Better: Create a helper script in your infrastructure repo:**

```bash
# /opt/infrastructure/scripts/update-caddy.sh
#!/bin/bash
exec /opt/hosting-blueprint/scripts/update-caddy.sh \
  /opt/infrastructure/infra/reverse-proxy
```

### Check DNS Exposure

```bash
# Run from anywhere
sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh yourdomain.com
```

### Prepare SSH Keys (Local Machine)

```bash
# On your local machine
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm/main/scripts/prepare-ssh-keys.sh | bash
```

## Updating Template Scripts

When new scripts are added to the template:

```bash
# Pull latest template updates
cd /opt/hosting-blueprint
git pull origin master

# New scripts are now available
ls scripts/

# Use them with your infrastructure
sudo /opt/hosting-blueprint/scripts/new-script.sh
```

## GitOps Workflow

Your infrastructure repo (`/opt/infrastructure`) should be connected to GitHub Actions:

```mermaid
graph LR
    A[Local Dev] -->|git push| B[GitHub]
    B -->|GitHub Actions| C[Deploy to VM]
    C -->|Update| D[/opt/infrastructure]
```

### Branches:
- `dev` → deploys to dev-app.yourdomain.com
- `staging` → deploys to staging-app.yourdomain.com
- `main` → deploys to app.yourdomain.com

## Configuration Management

### Environment-Specific Configs

```
/opt/infrastructure/apps/myapp/
├── compose.dev.yml        # Dev overrides
├── compose.staging.yml    # Staging overrides
├── compose.production.yml # Production overrides
├── .env.dev
├── .env.staging
└── .env.production
```

### Secrets (Not in Git)

```bash
# Create secrets (not tracked in git)
/opt/hosting-blueprint/scripts/secrets/create-secret.sh dev db_password

# Stored in /opt/infrastructure/secrets/dev/db_password
# Referenced in compose.yml as:
# secrets:
#   db_password:
#     file: ../../secrets/dev/db_password
```

## Why Separate Directories?

| Directory | Purpose | Git | Updates |
|-----------|---------|-----|---------|
| `/opt/hosting-blueprint` | Setup scripts & docs | Template repo | `git pull` for new scripts |
| `/opt/infrastructure` | Running services | Your repo | `git push` your changes |

**Benefits:**
- ✅ Clear separation of concerns
- ✅ Template updates don't break your config
- ✅ Your infrastructure is version controlled
- ✅ Team can collaborate on your infrastructure repo
- ✅ CI/CD deploys to `/opt/infrastructure`
- ✅ Scripts remain available for maintenance tasks

## Migration for Existing Users

If you've been using `/opt/hosting-blueprint` for services:

```bash
# 1. Create infrastructure directory
sudo mkdir -p /opt/infrastructure
sudo chown $USER:$USER /opt/infrastructure

# 2. Move running services
sudo mv /opt/hosting-blueprint/infra /opt/infrastructure/
sudo mv /opt/hosting-blueprint/apps /opt/infrastructure/

# 3. Update docker compose paths (if needed)
cd /opt/infrastructure/infra/reverse-proxy
# Check compose.yml for any absolute paths

# 4. Initialize git repo
cd /opt/infrastructure
git init
git add .
git commit -m "Migrate infrastructure from hosting-blueprint"

# 5. Continue using hosting-blueprint for scripts
cd /opt/hosting-blueprint
git pull  # Won't affect your running services anymore
```

## Summary

- **Template** (`/opt/hosting-blueprint`): Setup scripts, docs, reference
- **Infrastructure** (`/opt/infrastructure`): Your actual running services
- **Scripts**: Run from template, act on infrastructure
- **Git**: Template is upstream, infrastructure is yours
- **Updates**: Pull template for new scripts, push infrastructure for deployments
