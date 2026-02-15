# Operations Runbook

Daily operations, deployment, troubleshooting, and maintenance guide.

---

## Directory Structure

| Path | Purpose |
|------|---------|
| `/opt/hosting-blueprint` | Repository with scripts, configs, templates |
| `/srv/apps/{dev,staging,production}` | Deployed applications |

---

## Quick Reference Commands

```bash
# SSH to server (via tunnel - requires ~/.ssh/config)
ssh myserver

# Or with full command
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.yourdomain.com" sysadmin@ssh.yourdomain.com

# Check system status
sudo docker ps                                    # All containers
sudo systemctl status cloudflared            # Tunnel status
cd /opt/hosting-blueprint/infra/reverse-proxy && sudo docker compose ps  # Caddy status

# View logs
sudo docker compose logs -f                       # Current directory
sudo journalctl -u cloudflared -f            # Tunnel logs
sudo ufw status verbose                      # Firewall rules

# Deploy/Update app (CI/CD deploys to /srv/apps/)
cd /srv/apps/production/my-app
sudo docker compose pull
sudo docker compose up -d

# Restart services
sudo docker compose restart                       # Current app
sudo docker compose restart caddy                 # In reverse-proxy dir
sudo systemctl restart cloudflared           # Tunnel

# Check systemd auto-start services
sudo systemctl status docker-compose@production
sudo systemctl status docker-compose@staging
```

---

## Application Deployment

### Deploy New App

1. **Copy template:**
   ```bash
   cd /opt/hosting-blueprint/apps
   cp -r _template my-new-app
   cd my-new-app
   ```

2. **Configure:**
   ```bash
   cp .env.example .env
   nano .env  # Set ENVIRONMENT, APP_NAME, DOCKER_NETWORK, etc.
   nano compose.yml  # Update image, ports, healthcheck
   ```

3. **Deploy:**
   ```bash
   sudo docker compose pull  # or build
   sudo docker compose up -d
   sudo docker compose ps
   sudo docker compose logs -f
   ```

4. **Add to Caddy:**
   ```bash
   cd ../../infra/reverse-proxy
   nano Caddyfile
   ```

   Add block:
   ```caddyfile
   http://staging-my-app.yourdomain.com {
     import security_headers
     reverse_proxy app-my-new-app:3000 {
       import proxy_headers
     }
   }
   ```

   Restart:
   ```bash
   sudo docker compose restart caddy
   ```

5. **Test:**
   ```bash
   curl https://staging-my-app.yourdomain.com
   ```

### Update Existing App

```bash
cd apps/my-app

# Pull latest image
sudo docker compose pull

# Restart with new image (zero-downtime if health checks configured)
sudo docker compose up -d

# Verify
sudo docker compose ps
sudo docker compose logs --tail=50
```

### Rollback App

**Option 1: Git-based rollback (recommended for CI/CD deployments)**

```bash
cd /srv/apps/production/my-app

# View recent commits
git log --oneline -10

# Rollback to specific commit
git reset --hard <commit-hash>

# Or rollback to previous commit
git reset --hard HEAD~1

# Restart containers with previous version
sudo docker compose pull
sudo docker compose up -d

# Verify
sudo docker compose ps
```

**Option 2: Docker image tag rollback**

```bash
cd /srv/apps/production/my-app

# View available images
docker images | grep my-app

# Update compose.yml to use previous tag
nano compose.yml  # Change image: my-app:v1.0.1

# Deploy
sudo docker compose up -d
```

**Option 3: Quick rollback using git reflog**

```bash
cd /srv/apps/production/my-app

# View all recent git operations (including failed deploys)
git reflog

# Restore to specific reflog entry
git reset --hard HEAD@{2}

sudo docker compose up -d
```

---

## Monitoring & Logs

### View Container Logs

```bash
# All logs
sudo docker compose logs

# Follow logs
sudo docker compose logs -f

# Last 100 lines
sudo docker compose logs --tail=100

# Specific service
sudo docker compose logs -f app

# Since timestamp
sudo docker compose logs --since 2024-01-01T10:00:00
```

### View System Logs

```bash
# Tunnel logs
sudo journalctl -u cloudflared -f

# Docker daemon logs
sudo journalctl -u docker -f

# System logs
sudo journalctl -xe

# SSH attempts (fail2ban)
sudo journalctl -u fail2ban -f
```

### Check Resource Usage

```bash
# Container resource usage
sudo docker stats

# Disk usage
df -h
sudo docker system df -v

# Memory usage
free -h

# CPU load
uptime
htop
```

### Caddy Access Logs

```bash
cd infra/reverse-proxy

# View logs
sudo docker compose exec caddy tail -f /data/logs/staging-access.log
sudo docker compose exec caddy tail -f /data/logs/production-access.log

# Parse JSON logs
sudo docker compose exec caddy cat /data/logs/production-access.log | jq .
```

---

## Troubleshooting

### App Not Accessible (502/504)

**Check tunnel:**
```bash
sudo systemctl status cloudflared
sudo journalctl -u cloudflared --since "5 minutes ago"
```

**Check Caddy:**
```bash
cd infra/reverse-proxy
sudo docker compose ps
sudo docker compose logs caddy --tail=50
```

**Check app:**
```bash
cd apps/my-app
sudo docker compose ps
sudo docker compose logs --tail=50
```

**Test connectivity:**
```bash
# From Caddy to app
cd infra/reverse-proxy
sudo docker compose exec caddy wget -O- http://app-staging:80
```

### Container Keeps Restarting

```bash
# Check logs
sudo docker compose logs app

# Check health
sudo docker inspect app-staging | grep -A 20 Health

# Test health endpoint manually
sudo docker compose exec app wget -O- http://localhost:3000/health
```

### High Memory Usage

```bash
# Find container using most memory
sudo docker stats --no-stream | sort -k4 -h

# Restart specific container
sudo docker compose restart app

# Adjust resource limits in compose.yml
nano compose.yml  # Update deploy.resources.limits
sudo docker compose up -d
```

### Disk Space Full

```bash
# Check disk usage
df -h
sudo docker system df

# Clean up
sudo docker system prune -a --volumes
# WARNING: Removes unused containers, images, volumes

# Safe cleanup (keep running containers)
sudo docker image prune -a
sudo docker volume prune
sudo docker builder prune
```

### DNS Not Resolving

**Check Cloudflare DNS:**
1. Go to Cloudflare Dashboard � DNS
2. Verify CNAME records exist
3. Check proxy status (orange cloud)

**Test DNS:**
```bash
# From your workstation
dig staging-app.yourdomain.com
nslookup staging-app.yourdomain.com

# Should show Cloudflare IPs
```

**Check tunnel routes:**
```bash
cloudflared tunnel route dns
cloudflared tunnel info production-tunnel
```

---

## Maintenance Tasks

### Update System Packages

```bash
# Update packages (as sysadmin)
sudo apt update
sudo apt upgrade -y

# Check if reboot required
if [ -f /var/run/reboot-required ]; then
  cat /var/run/reboot-required.pkgs
fi
```

### Update Docker Images

```bash
# Update all apps
for app in /opt/hosting-blueprint/apps/*/; do
  cd "$app"
  if [ -f compose.yml ]; then
    echo "Updating $(basename $app)..."
    sudo docker compose pull
    sudo docker compose up -d
  fi
done
```

### Update cloudflared

```bash
# Via apt
sudo apt update
sudo apt upgrade cloudflared

# Restart service
sudo systemctl restart cloudflared

# Verify
cloudflared --version
```

### Rotate Secrets

```bash
# Update .env file
cd apps/my-app
nano .env  # Update secrets

# Restart app to load new secrets
sudo docker compose up -d --force-recreate
```

### Clean Up Old Images

```bash
# Remove unused images
sudo docker image prune -a

# Remove specific old tags
docker rmi my-app:v1.0.0
```

### Automated Maintenance Scripts

This repository includes ready-to-use maintenance scripts in `scripts/maintenance/`:

#### Docker Cleanup (`docker-cleanup.sh`)

Safely removes unused Docker resources:

```bash
# Preview what would be removed (safe)
./scripts/maintenance/docker-cleanup.sh --dry-run

# Standard cleanup (removes stopped containers, dangling images, unused networks)
./scripts/maintenance/docker-cleanup.sh

# Full cleanup with confirmation (removes ALL unused resources including volumes)
./scripts/maintenance/docker-cleanup.sh --full

# Full cleanup without confirmation (for cron/automation)
./scripts/maintenance/docker-cleanup.sh --full --force
```

**Cron setup for weekly cleanup:**
```bash
# Add to /etc/cron.d/vm-maintenance or crontab
0 3 * * 0 root /opt/hosting-blueprint/scripts/maintenance/docker-cleanup.sh >> /var/log/docker-cleanup.log 2>&1
```

#### Volume Backup (`backup-volumes.sh`)

Backup Docker volumes with retention policies:

```bash
# Backup all volumes
./scripts/maintenance/backup-volumes.sh

# Backup specific volume
./scripts/maintenance/backup-volumes.sh my-app-data

# Restore a volume
./scripts/maintenance/backup-volumes.sh --restore backup-20240101-120000.tar.gz my-app-data
```

**Note:** Backups are stored in `/var/backups/docker-volumes/` by default.

#### Disk Usage Check (`check-disk-usage.sh`)

Lightweight disk monitoring for cron (logs warnings to syslog):

```bash
# Manual run
./scripts/maintenance/check-disk-usage.sh

# Check with custom threshold (default: 85%)
DISK_THRESHOLD=90 ./scripts/maintenance/check-disk-usage.sh
```

**Cron setup for hourly checks:**
```bash
# Add to /etc/cron.d/vm-maintenance
0 * * * * root /opt/hosting-blueprint/scripts/maintenance/check-disk-usage.sh
```

Warnings appear in:
- System log: `journalctl -t disk-check`
- `/var/log/syslog`

---

## Backup & Recovery

### Backup Application Data

```bash
# Stop app
cd apps/my-app
sudo docker compose down

# Backup volumes
sudo tar -czf /tmp/my-app-backup-$(date +%Y%m%d).tar.gz ./data

# Restart app
sudo docker compose up -d

# Move backup off-server
scp /tmp/my-app-backup-*.tar.gz backup-server:/backups/
```

### Backup Docker Volumes

```bash
# List volumes
sudo docker volume ls

# Backup specific volume
sudo docker run --rm \
  -v my-app-data:/data \
  -v /tmp:/backup \
  alpine tar -czf /backup/volume-backup.tar.gz /data
```

### Restore From Backup

```bash
# Stop app
cd apps/my-app
sudo docker compose down

# Extract backup
sudo tar -xzf /tmp/my-app-backup-20241201.tar.gz -C ./

# Start app
sudo docker compose up -d
```

---

## Security Operations

### Review Firewall Rules

```bash
sudo ufw status verbose
sudo ufw status numbered
```

### Check SSH Access Logs

```bash
# Recent SSH attempts
sudo journalctl -u sshd --since "1 hour ago"

# fail2ban status
sudo fail2ban-client status sshd
```

### Audit Docker Containers

```bash
# Check security settings
sudo docker inspect app-staging | jq '.[0].HostConfig.SecurityOpt'
sudo docker inspect app-staging | jq '.[0].HostConfig.CapDrop'

# Check running as root (should be non-root)
docker top app-staging
```

### Update SSL Certificates

Certificates are managed by Cloudflare. If using direct HTTPS with Caddy:

```bash
cd infra/reverse-proxy
sudo docker compose restart caddy  # Caddy auto-renews
```

---

## Emergency Procedures

### Complete System Outage

1. **Check tunnel:**
   ```bash
   sudo systemctl status cloudflared
   sudo systemctl restart cloudflared
   ```

2. **Check Caddy:**
   ```bash
   cd infra/reverse-proxy
   sudo docker compose ps
   sudo docker compose restart
   ```

3. **Check apps:**
   ```bash
   sudo docker ps -a
   sudo docker compose up -d  # In each app directory
   ```

### Rollback All Apps

```bash
# Create rollback script
cat > /tmp/rollback.sh <<'EOF'
#!/bin/bash
for app in /opt/hosting-blueprint/apps/*/; do
  cd "$app"
  if [ -f compose.yml ]; then
    echo "Rolling back $(basename $app)..."
    # Pull previous tag or use git to checkout previous version
    sudo docker compose down
    sudo docker compose up -d
  fi
done
EOF

chmod +x /tmp/rollback.sh
/tmp/rollback.sh
```

### Disable App Temporarily

```bash
# Stop specific app
cd apps/problematic-app
sudo docker compose down

# Or remove from Caddy
cd infra/reverse-proxy
nano Caddyfile  # Comment out app block
sudo docker compose restart caddy
```

---

## Performance Optimization

### Identify Slow Containers

```bash
# Check container stats
sudo docker stats --no-stream

# Check restart count
sudo docker ps -a --format "table {{.Names}}\t{{.Status}}"
```

### Optimize Images

```bash
# Check image sizes
docker images

# Use multi-stage builds (see apps/examples/simple-api/Dockerfile)
# Use alpine base images
# Remove unnecessary dependencies
```

### Adjust Resource Limits

```bash
cd apps/my-app
nano compose.yml

# Update limits based on actual usage
deploy:
  resources:
    limits:
      cpus: '1.0'
      memory: 1G
```

---

## Common Workflows

### Add New Subdomain

1. Add to Caddyfile
2. Restart Caddy
3. Test: `curl https://new-subdomain.yourdomain.com`

### Migrate App from Staging to Production

```bash
# Copy app
cp -r apps/staging-app apps/production-app
cd apps/production-app

# Update .env
nano .env  # Change to ENVIRONMENT=production, DOCKER_NETWORK=prod-web

# Deploy
sudo docker compose up -d

# Add to Caddy (production block)
# Restart Caddy
```

### Scale Up Server Resources

After upgrading VM (more CPU/RAM):

```bash
# Update resource limits in compose files
# Restart containers to apply new limits
sudo docker compose up -d --force-recreate
```

---

## Monitoring Checklist (Daily/Weekly)

### Daily Checks

```bash
# All containers running
sudo docker ps

# Tunnel connected
sudo systemctl status cloudflared

# Disk space okay (>20% free)
df -h

# No container restarts
sudo docker ps --format "table {{.Names}}\t{{.Status}}"
```

### Weekly Checks

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Clean unused Docker resources
sudo docker system prune -f

# Review logs for errors
sudo journalctl --since "7 days ago" | grep -i error

# Check fail2ban
sudo fail2ban-client status
```

---

## Getting Help

- **Architecture:** [docs/04-architecture.md](docs/04-architecture.md)
- **Troubleshooting:** [docs/05-troubleshooting.md](docs/05-troubleshooting.md)
- **Security:** [docs/02-security-hardening.md](docs/02-security-hardening.md)
- **Cloudflare:** [infra/cloudflared/tunnel-setup.md](infra/cloudflared/tunnel-setup.md)
