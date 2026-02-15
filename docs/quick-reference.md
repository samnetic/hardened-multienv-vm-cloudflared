# Quick Reference

Fast reference for common tasks on your VM.

## 📍 Directory Structure

```
/opt/
├── hosting-blueprint/     # Template repo (setup scripts, docs)

/srv/
├── infrastructure/        # Your infrastructure code (Caddy, monitoring)
└── apps/
    ├── dev/               # Dev deployments
    ├── staging/           # Staging deployments
    └── production/        # Production deployments

/var/
└── secrets/               # Secrets (NOT in git)
```

## 🚀 First-Time Setup on Your VM

### 1. Update Template Scripts
```bash
# From your local machine (after running scripts/setup-local-ssh.sh):
ssh yourdomain
cd /opt/hosting-blueprint
git pull origin main
```

### 2. Initialize /srv/infrastructure (Recommended)
```bash
sudo /opt/hosting-blueprint/scripts/setup-infrastructure-repo.sh yourdomain.com
```

### 3. Configure Caddy with Your Domain
```bash
cd /srv/infrastructure/reverse-proxy

# Update domain (replace example.com with YOUR domain)
sed -i 's/yourdomain.com/example.com/g' Caddyfile

# Safely apply
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
```

### 4. Start Caddy
```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose up -d
```

## 🔧 Daily Operations

### Edit Caddy Configuration

```bash
# 1. Edit Caddyfile
vim /srv/infrastructure/reverse-proxy/Caddyfile

# 2. Validate and apply (zero downtime)
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy

# 3. Commit changes
cd /srv/infrastructure
git add reverse-proxy/Caddyfile
git commit -m "Update Caddy config"
git push
```

### Check Caddy Status

```bash
# Is it running?
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml ps

# View logs
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs -f

# Check errors
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs | grep -i error
```

### Deploy New App

```bash
cd /srv/apps/production

# Copy template
cp -r /opt/hosting-blueprint/apps/_template myapp

# Configure
cd myapp
vim compose.yml  # Update service name, ports, etc.
vim .env         # Set environment variables

# Start app
sudo docker compose up -d

# Verify
sudo docker compose ps
sudo docker compose logs -f
```

### Add App to Caddy

```bash
# 1. Edit Caddyfile
vim /srv/infrastructure/reverse-proxy/Caddyfile

# Add:
http://myapp.yourdomain.com {
  import security_headers
  reverse_proxy app-myapp:8080 {
    import proxy_headers
  }
}

# 2. Apply changes
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
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
sudo docker ps
```

### View All Networks
```bash
sudo docker network ls
```

### Check Resource Usage
```bash
sudo docker stats --no-stream
```

### Clean Up Unused Images
```bash
sudo docker system prune -a
```

### Restart All Services
```bash
# Reverse proxy
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml restart

# Specific app
sudo docker compose -f /srv/apps/production/myapp/compose.yml restart
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
cp /srv/infrastructure/reverse-proxy/Caddyfile \
   /srv/infrastructure/reverse-proxy/Caddyfile.backup
```

### View Auto Backups
```bash
ls -lt /srv/infrastructure/reverse-proxy/backups/
```

### Restore Backup
```bash
# Find backup
ls /srv/infrastructure/reverse-proxy/backups/

# Restore (replace TIMESTAMP)
cp /srv/infrastructure/reverse-proxy/backups/Caddyfile.YYYYMMDD_HHMMSS \
   /srv/infrastructure/reverse-proxy/Caddyfile

# Apply
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
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
sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml \
  exec caddy cat /data/logs/production-access.log | tail -50

# App logs
sudo docker compose -f /srv/apps/production/myapp/compose.yml logs -f
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
   sudo docker ps | grep myapp
   ```

2. **Check Caddy config:**
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

### Caddy Won't Start

1. **Check syntax:**
   ```bash
   sudo docker run --rm --network none \
     -v /srv/infrastructure/reverse-proxy/Caddyfile:/etc/caddy/Caddyfile:ro \
     caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
   ```

2. **View error logs:**
   ```bash
   sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs
   ```

3. **Restore backup:**
   ```bash
   ls /srv/infrastructure/reverse-proxy/backups/
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
- **GitHub Repo:** https://github.com/samnetic/hardened-multienv-vm-cloudflared
- **Caddy Docs:** https://caddyserver.com/docs/

## 💡 Pro Tips

1. **Always use the update-caddy.sh script** - it prevents outages
2. **Test in dev first** - use dev-app.yourdomain.com for testing
3. **Commit Caddy changes** - version control your infrastructure
4. **Keep backups** - automatic backups are in backups/ folder
5. **Monitor logs** - check logs after making changes
6. **Use snippets** - DRY principle for repeated Caddy configs
