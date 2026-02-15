# Getting Started

Quick start guide for setting up your infrastructure on an existing VM with cloudflared already configured.

## ✅ Prerequisites

You already have:
- ✅ VM running (Oracle Cloud, AWS, GCP, DigitalOcean, Hetzner, etc.)
- ✅ Cloudflared tunnel set up
- ✅ SSH access via tunnel (recommended: short SSH alias via `scripts/setup-local-ssh.sh`)
- ✅ Domain configured in Cloudflare

## 🚀 One-Command Setup

SSH to your VM and run:

```bash
# From your LOCAL machine (recommended):
# 1) Configure tunnel SSH once (creates a short alias like: ssh yourdomain)
# curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com sysadmin
#
# 2) SSH using the generated alias (first label of your domain)
ssh yourdomain

# Update template scripts
cd /opt/hosting-blueprint
git pull origin main

# Set up infrastructure (automated)
sudo /opt/hosting-blueprint/scripts/setup-infrastructure-repo.sh yourdomain.com myproject-infrastructure
```

This will:
1. Create `/srv/infrastructure` directory
2. Copy templates
3. Update Caddyfile with your domain
4. Initialize git repository
5. Create GitHub repo (optional)
6. Start Caddy
7. Validate setup

## 📝 What You Get

```
/srv/
├── infrastructure/          # Infrastructure repo (git tracked)
│   ├── reverse-proxy/
│   │   ├── Caddyfile       # ← Configure your subdomains here
│   │   └── compose.yml
│   └── monitoring/
└── apps/                   # Your applications
    ├── dev/
    ├── staging/
    └── production/

/var/secrets/               # Secrets (NOT in git)
```

## 🎨 Editing Caddyfile (Safe Way)

```bash
# 1. Edit Caddyfile
vim /srv/infrastructure/reverse-proxy/Caddyfile

# 2. Apply safely (validates before applying)
sudo /opt/hosting-blueprint/scripts/update-caddy.sh

# 3. Commit changes
cd /srv/infrastructure
git add reverse-proxy/Caddyfile
git commit -m "Add new app route"
git push
```

**The script prevents outages by:**
- ✅ Validating syntax before applying
- ✅ Creating timestamped backups
- ✅ Zero-downtime reload
- ✅ Auto-rollback on failure

## 📦 Deploying Your First App

```bash
# 1. Create app from template
sudo mkdir -p /srv/apps/production
sudo cp -r /opt/hosting-blueprint/apps/_template /srv/apps/production/myapp

# 2. Configure
cd /srv/apps/production/myapp
vim compose.yml  # Set image, ports, etc.
vim .env         # Environment variables

# 3. Start app
sudo docker compose up -d

# 4. Add to Caddy
vim /srv/infrastructure/reverse-proxy/Caddyfile

# Add this block:
http://myapp.yourdomain.com {
  import security_headers
  reverse_proxy app-myapp:8080 {
    import proxy_headers
  }
}

# 5. Apply Caddy config
sudo /opt/hosting-blueprint/scripts/update-caddy.sh

# 6. Add DNS in Cloudflare
# Type: CNAME
# Name: myapp
# Target: <your-tunnel-id>.cfargotunnel.com
# Proxy: ON (orange cloud)

# 7. Test
curl https://myapp.yourdomain.com
```

### Included Examples

This template includes ready-to-copy examples under `apps/examples/`:

- `hello-world/` (static nginx demo)
- `simple-api/` (Node.js API + hardened compose)
- `python-fastapi/` (FastAPI app + hardened compose)
- `postgres/` (backend-only Postgres with file-based secrets)

## 🌐 DNS Configuration

Your Cloudflare DNS should have:

| Type | Name | Target | Proxy |
|------|------|--------|-------|
| CNAME | ssh | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | @ | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | * | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | dev-app | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | staging-app | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | app | `<tunnel-id>.cfargotunnel.com` | ON |

**Remove any A records pointing to your VM IP.**

## 🔒 Security Check

After setup, verify zero-trust security:

```bash
sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh yourdomain.com
```

This checks if your VM IP is exposed via DNS A records.

## 🔄 GitOps CI/CD (Optional)

Set up automated deployments:

```bash
/opt/hosting-blueprint/scripts/init-gitops.sh
```

This configures:
- GitHub Actions secrets
- Deployment workflows
- Branch strategy (dev → staging → main)

## 📚 Documentation

Complete guides in `/opt/hosting-blueprint/docs/`:

- `filesystem-layout.md` - Directory structure explained
- `caddy-configuration-guide.md` - Caddy config examples
- `quick-reference.md` - Command cheat sheet
- `00-initial-setup.md` - Full initial setup guide

## 🛠️ Common Tasks

### View Caddy Logs
```bash
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs -f
```

### Restart Caddy
```bash
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml restart
```

### List Running Containers
```bash
sudo docker ps
```

### Check Disk Usage
```bash
df -h
sudo docker system df
```

### Clean Up Docker
```bash
sudo docker system prune -a  # Remove unused images
```

## 🆘 Troubleshooting

### App Not Accessible

1. **Check container running:**
   ```bash
   sudo docker ps | grep myapp
   ```

2. **Check Caddy logs:**
   ```bash
   sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs | grep myapp
   ```

3. **Check DNS:**
   ```bash
   dig myapp.yourdomain.com
   ```

4. **Test locally:**
   ```bash
   curl -H "Host: myapp.yourdomain.com" http://localhost
   ```

### Caddy Config Error

```bash
# View backups
ls -lt /srv/infrastructure/reverse-proxy/backups/

# Restore backup (replace TIMESTAMP)
cp /srv/infrastructure/reverse-proxy/backups/Caddyfile.YYYYMMDD_HHMMSS \
   /srv/infrastructure/reverse-proxy/Caddyfile

# Reload
sudo /opt/hosting-blueprint/scripts/update-caddy.sh
```

## 🎯 Recommended Workflow

1. **Make changes in git branches**
   ```bash
   cd /srv/infrastructure
   git checkout -b add-new-app
   vim reverse-proxy/Caddyfile
   ```

2. **Test changes**
   ```bash
   sudo /opt/hosting-blueprint/scripts/update-caddy.sh
   ```

3. **Commit and push**
   ```bash
   git add .
   git commit -m "Add new app route"
   git push -u origin add-new-app
   ```

4. **Create PR, review, merge to main**

5. **Pull on server**
   ```bash
   git checkout main
   git pull
   sudo /opt/hosting-blueprint/scripts/update-caddy.sh
   ```

## 🚀 You're Ready!

Your VM is now:
- ✅ Organized with FHS-compliant structure
- ✅ Protected by zero-trust security
- ✅ Ready for application deployments
- ✅ Version controlled with git
- ✅ Safe from configuration errors

**Next:** Deploy your first app and enjoy zero-port security! 🎉
