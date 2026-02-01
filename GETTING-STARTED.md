# Getting Started - codeagen.com

Quick start guide for setting up your infrastructure on an existing VM with cloudflared already configured.

## ✅ Prerequisites

You already have:
- ✅ Oracle OCI VM running
- ✅ Cloudflared tunnel set up
- ✅ SSH access via `ssh.codeagen.com`
- ✅ Domain configured in Cloudflare

## 🚀 One-Command Setup

SSH to your VM and run:

```bash
ssh sysadmin@ssh.codeagen.com

# Update template scripts
cd /opt/hosting-blueprint
git pull origin master

# Set up infrastructure (automated)
sudo /opt/hosting-blueprint/scripts/setup-infrastructure-repo.sh codeagen.com codeagen-infrastructure
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
    ├── _template/         # Copy this for new apps
    ├── myapp-dev/
    ├── myapp-staging/
    └── myapp-production/

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
cd /srv/apps
cp -r _template myapp-production

# 2. Configure
cd myapp-production
vim compose.yml  # Set image, ports, etc.
vim .env         # Environment variables

# 3. Start app
docker compose up -d

# 4. Add to Caddy
vim /srv/infrastructure/reverse-proxy/Caddyfile

# Add this block:
http://myapp.codeagen.com {
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
curl https://myapp.codeagen.com
```

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
sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh codeagen.com
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
docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs -f
```

### Restart Caddy
```bash
docker compose -f /srv/infrastructure/reverse-proxy/compose.yml restart
```

### List Running Containers
```bash
docker ps
```

### Check Disk Usage
```bash
df -h
docker system df
```

### Clean Up Docker
```bash
docker system prune -a  # Remove unused images
```

## 🆘 Troubleshooting

### App Not Accessible

1. **Check container running:**
   ```bash
   docker ps | grep myapp
   ```

2. **Check Caddy logs:**
   ```bash
   docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs | grep myapp
   ```

3. **Check DNS:**
   ```bash
   dig myapp.codeagen.com
   ```

4. **Test locally:**
   ```bash
   curl -H "Host: myapp.codeagen.com" http://localhost
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
