# Quick Reference

Fast reference for common tasks on your VM.

## 📍 Directory Structure

```
/opt/
├── hosting-blueprint/     # Template repo (setup scripts, docs)
└── infrastructure/        # YOUR infrastructure (running services)
    ├── infra/reverse-proxy/  # ← Caddy config here
    └── apps/                 # ← Your apps here
```

## 🚀 First-Time Setup on Your VM

### 1. Update Template Scripts
```bash
ssh sysadmin@ssh.yourdomain.com
cd /opt/hosting-blueprint
git pull origin master
```

### 2. Create Infrastructure Repo
```bash
# Create directory
sudo mkdir -p /opt/infrastructure
sudo chown sysadmin:sysadmin /opt/infrastructure

# Copy templates
cp -r /opt/hosting-blueprint/infra /opt/infrastructure/
cp -r /opt/hosting-blueprint/apps /opt/infrastructure/
cp /opt/hosting-blueprint/.gitignore /opt/infrastructure/

# Initialize git
cd /opt/infrastructure
git init
git add .
git commit -m "Initial infrastructure setup"

# Link to GitHub (create repo first on GitHub)
git remote add origin https://github.com/YOUR_USERNAME/myproject-infrastructure.git
git push -u origin main
```

### 3. Configure Caddy with Your Domain
```bash
cd /opt/infrastructure/infra/reverse-proxy

# Update domain (replace example.com with YOUR domain)
sed -i 's/yourdomain.com/example.com/g' Caddyfile

# Safely apply
sudo /opt/hosting-blueprint/scripts/update-caddy.sh
```

### 4. Start Caddy
```bash
cd /opt/infrastructure/infra/reverse-proxy
docker compose up -d
```

## 🔧 Daily Operations

### Edit Caddy Configuration

```bash
# 1. Edit Caddyfile
vim /opt/infrastructure/infra/reverse-proxy/Caddyfile

# 2. Validate and apply (zero downtime)
sudo /opt/hosting-blueprint/scripts/update-caddy.sh

# 3. Commit changes
cd /opt/infrastructure
git add infra/reverse-proxy/Caddyfile
git commit -m "Update Caddy config"
git push
```

### Check Caddy Status

```bash
# Is it running?
docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml ps

# View logs
docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml logs -f

# Check errors
docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml logs | grep -i error
```

### Deploy New App

```bash
cd /opt/infrastructure/apps

# Copy template
cp -r _template myapp

# Configure
cd myapp
vim compose.yml  # Update service name, ports, etc.
vim .env         # Set environment variables

# Start app
docker compose up -d

# Verify
docker compose ps
docker compose logs -f
```

### Add App to Caddy

```bash
# 1. Edit Caddyfile
vim /opt/infrastructure/infra/reverse-proxy/Caddyfile

# Add:
http://myapp.yourdomain.com {
  import security_headers
  reverse_proxy app-myapp:8080 {
    import proxy_headers
  }
}

# 2. Apply changes
sudo /opt/hosting-blueprint/scripts/update-caddy.sh
```

### Add DNS in Cloudflare

1. Go to: https://dash.cloudflare.com
2. Select: yourdomain.com
3. DNS → Add record:
   - **Type:** CNAME
   - **Name:** myapp (or dev-app, staging-app, etc.)
   - **Target:** `<your-tunnel-id>.cfargotunnel.com`
   - **Proxy:** ON (orange cloud)
4. Wait 1-2 minutes for DNS propagation
5. Test: `curl https://myapp.yourdomain.com`

## 🔐 Security Checks

### Check DNS Exposure
```bash
sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh yourdomain.com
```

### Verify Setup
```bash
sudo /opt/hosting-blueprint/scripts/verify-setup.sh
```

### View Firewall Status
```bash
sudo ufw status
```

## 🐳 Docker Commands

### List Running Containers
```bash
docker ps
```

### View All Networks
```bash
docker network ls
```

### Check Resource Usage
```bash
docker stats --no-stream
```

### Clean Up Unused Images
```bash
docker system prune -a
```

### Restart All Services
```bash
# Reverse proxy
docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml restart

# Specific app
docker compose -f /opt/infrastructure/apps/myapp/compose.yml restart
```

## 📝 Common Caddy Configurations

### Basic App
```caddyfile
http://app.yourdomain.com {
  import security_headers
  reverse_proxy app-production:80 {
    import proxy_headers
  }
}
```

### API with CORS
```caddyfile
http://api.yourdomain.com {
  import security_headers

  header {
    Access-Control-Allow-Origin *
    Access-Control-Allow-Methods "GET, POST, PUT, DELETE"
  }

  reverse_proxy api-production:3000 {
    import proxy_headers
  }
}
```

### Static Files
```caddyfile
http://static.yourdomain.com {
  import security_headers
  root * /srv/static
  file_server
}
```

### Redirect
```caddyfile
http://old.yourdomain.com {
  redir https://new.yourdomain.com{uri} permanent
}
```

## 🔄 Backup & Rollback

### Manual Backup
```bash
# Backup Caddyfile
cp /opt/infrastructure/infra/reverse-proxy/Caddyfile \
   /opt/infrastructure/infra/reverse-proxy/Caddyfile.backup
```

### View Auto Backups
```bash
ls -lt /opt/infrastructure/infra/reverse-proxy/backups/
```

### Restore Backup
```bash
# Find backup
ls /opt/infrastructure/infra/reverse-proxy/backups/

# Restore (replace TIMESTAMP)
cp /opt/infrastructure/infra/reverse-proxy/backups/Caddyfile.YYYYMMDD_HHMMSS \
   /opt/infrastructure/infra/reverse-proxy/Caddyfile

# Apply
sudo /opt/hosting-blueprint/scripts/update-caddy.sh
```

## 🌐 DNS Configuration

Your current setup should have:

| Record Type | Name | Target | Proxy |
|-------------|------|--------|-------|
| CNAME | ssh | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | @ | `<tunnel-id>.cfargotunnel.com` | ON |
| CNAME | * | `<tunnel-id>.cfargotunnel.com` | ON |

**Remove any A records** pointing to your VM IP.

## 📊 Monitoring

### View Logs
```bash
# Caddy access logs
docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml \
  exec caddy cat /data/logs/production-access.log | tail -50

# App logs
docker compose -f /opt/infrastructure/apps/myapp/compose.yml logs -f
```

### System Resources
```bash
# Disk usage
df -h

# Memory usage
free -h

# Load average
uptime
```

## 🆘 Troubleshooting

### App Not Accessible

1. **Check Docker container:**
   ```bash
   docker ps | grep myapp
   ```

2. **Check Caddy config:**
   ```bash
   docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml logs | grep myapp
   ```

3. **Check DNS:**
   ```bash
   dig myapp.yourdomain.com
   ```

4. **Test locally:**
   ```bash
   curl -H "Host: myapp.yourdomain.com" http://localhost
   ```

### Caddy Won't Start

1. **Check syntax:**
   ```bash
   docker run --rm \
     -v /opt/infrastructure/infra/reverse-proxy/Caddyfile:/etc/caddy/Caddyfile:ro \
     caddy:latest caddy validate --config /etc/caddy/Caddyfile
   ```

2. **View error logs:**
   ```bash
   docker compose -f /opt/infrastructure/infra/reverse-proxy/compose.yml logs
   ```

3. **Restore backup:**
   ```bash
   ls /opt/infrastructure/infra/reverse-proxy/backups/
   # Copy most recent working backup
   ```

### SSH Not Working via Tunnel

1. **Check Cloudflare tunnel:**
   ```bash
   sudo systemctl status cloudflared
   sudo journalctl -u cloudflared -n 50
   ```

2. **Check DNS:**
   ```bash
   dig ssh.yourdomain.com
   ```

3. **Test tunnel route:**
   ```bash
   cloudflared tunnel info <tunnel-name>
   ```

## 📚 Documentation

- **Full docs:** `/opt/hosting-blueprint/docs/`
- **Caddy guide:** `/opt/hosting-blueprint/docs/caddy-configuration-guide.md`
- **Directory structure:** `/opt/hosting-blueprint/docs/directory-structure.md`
- **Initial setup:** `/opt/hosting-blueprint/docs/00-initial-setup.md`

## 🔗 Quick Links

- **Cloudflare Dashboard:** https://dash.cloudflare.com
- **GitHub Repo:** https://github.com/samnetic/hardened-multienv-vm
- **Caddy Docs:** https://caddyserver.com/docs/

## 💡 Pro Tips

1. **Always use the update-caddy.sh script** - it prevents outages
2. **Test in dev first** - use dev-app.yourdomain.com for testing
3. **Commit Caddy changes** - version control your infrastructure
4. **Keep backups** - automatic backups are in backups/ folder
5. **Monitor logs** - check logs after making changes
6. **Use snippets** - DRY principle for repeated Caddy configs
