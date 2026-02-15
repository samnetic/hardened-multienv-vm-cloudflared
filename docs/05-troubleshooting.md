# Troubleshooting Guide

Common issues and solutions for the production hosting blueprint.

---

## Quick Diagnostic Commands

```bash
# Check all services
sudo docker ps                              # All containers
sudo systemctl status cloudflared      # Tunnel
cd infra/reverse-proxy && sudo docker compose ps  # Caddy

# Check logs
sudo docker compose logs -f                 # App logs
sudo journalctl -u cloudflared -f      # Tunnel logs
sudo tail -f /var/log/ufw.log         # Firewall logs

# Test connectivity
curl https://staging-app.yourdomain.com
curl -I https://app.yourdomain.com
```

---

## Site Not Accessible

### Symptom: 502 Bad Gateway

**Possible Causes:**
1. Tunnel not running
2. Caddy not running
3. App not running
4. Wrong network configuration

**Diagnosis:**
```bash
# 1. Check tunnel
sudo systemctl status cloudflared
sudo journalctl -u cloudflared --since "5 minutes ago"

# 2. Check Caddy
cd infra/reverse-proxy
sudo docker compose ps
sudo docker compose logs caddy --tail=50

# 3. Check app
cd apps/my-app
sudo docker compose ps
sudo docker compose logs --tail=50

# 4. Check networks
sudo docker network ls
sudo docker network inspect staging-web
```

**Solutions:**
```bash
# Restart tunnel
sudo systemctl restart cloudflared

# Restart Caddy
cd infra/reverse-proxy
sudo docker compose restart caddy

# Restart app
cd apps/my-app
sudo docker compose restart
```

### Symptom: 504 Gateway Timeout

**Cause:** App too slow to respond

**Diagnosis:**
```bash
# Check app health
sudo docker compose exec app wget -O- http://localhost:3000/health

# Check resource usage
sudo docker stats app-staging

# Check logs for errors
sudo docker compose logs --tail=100
```

**Solutions:**
```bash
# Increase health check timeout in compose.yml
healthcheck:
  timeout: 30s  # Increase from 10s

# Add more resources
deploy:
  resources:
    limits:
      memory: 1G  # Increase from 512M
```

### Symptom: 403 Forbidden (Caddy `tunnel_only`)

**What it means:**
- You are likely bypassing the tunnel (hitting the VM directly by IP / wrong DNS), or
- A container is trying to reach Caddy directly (container-to-container bypass attempt), or
- `hosting-caddy-origin` is missing/misconfigured.

**Diagnosis:**
```bash
# 1) Make sure you’re using the Cloudflare hostname (not the VM IP).

# 2) Confirm Caddy is published to localhost only
sudo docker ps --filter name=caddy --format '{{.Ports}}'

# Expected: 127.0.0.1:80->80/tcp (no 0.0.0.0 binds)

# 3) Confirm the origin enforcement network exists and has the pinned gateway
sudo docker network inspect hosting-caddy-origin --format '{{(index .IPAM.Config 0).Gateway}}'

# Expected: 10.250.0.1
```

**Fix:**
```bash
# Create networks (includes hosting-caddy-origin)
sudo ./scripts/create-networks.sh

# Restart reverse proxy
cd /srv/infrastructure/reverse-proxy
sudo docker compose --compatibility up -d

# If you intentionally changed the gateway/subnet, update infra/reverse-proxy/Caddyfile (tunnel_only)
# then reload:
sudo ./scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
```

**Note:** This blueprint assumes `cloudflared` runs as a systemd service on the VM. If you run `cloudflared` inside Docker, you must adjust `tunnel_only` allowlists or migrate to the systemd service model.

### Symptom: SSL Certificate Error

**Cause:** Cloudflare SSL misconfigured

**Check:**
1. Cloudflare Dashboard → SSL/TLS → Overview
2. Encryption mode should be: **Full**
3. Always Use HTTPS: **On**

**Solution:**
- Wait 1-2 minutes after changing settings
- Clear browser cache
- Try incognito mode

---

## Container Issues

### Container Keeps Restarting

**Diagnosis:**
```bash
# Check restart count
sudo docker ps -a --format "table {{.Names}}\t{{.Status}}"

# View logs
sudo docker compose logs --tail=200

# Check health
sudo docker inspect app-staging | grep -A 20 Health
```

**Common Causes:**

**1. Failed Health Check**
```bash
# Test health endpoint manually
sudo docker compose exec app curl http://localhost:3000/health

# Fix: Update health check path or fix endpoint
```

**2. Out of Memory**
```bash
sudo docker stats

# Fix: Increase memory limit in compose.yml
```

**3. Missing Environment Variables**
```bash
# Check if .env file exists
ls -la .env

# Fix: Copy from example
cp .env.example .env
nano .env
```

### Container Won't Start

**Diagnosis:**
```bash
sudo docker compose logs app
sudo docker compose ps -a
sudo docker inspect app-staging
```

**Common Causes:**

**1. Port Already in Use**
```yaml
# Error: "port is already allocated"

# Find what's using the port
sudo netstat -tulpn | grep :3000

# Fix: Change port or stop conflicting service
```

**2. Volume Mount Error**
```yaml
# Error: "no such file or directory"

# Create missing directory
mkdir -p ./data

# Fix permissions
sudo chown -R $(whoami):$(whoami) ./data
```

**3. Network Doesn't Exist**
```bash
# Error: "network not found"

# Create networks
sudo ./scripts/create-networks.sh
```

---

## Tunnel Issues

### Tunnel Won't Connect

**Diagnosis:**
```bash
sudo journalctl -u cloudflared -f
sudo systemctl status cloudflared
```

**Common Issues:**

**1. Wrong Tunnel UUID**
```bash
# Check config
sudo cat /etc/cloudflared/config.yml

# List your tunnels
cloudflared tunnel list

# Fix: Update config with correct UUID
sudo nano /etc/cloudflared/config.yml
sudo systemctl restart cloudflared
```

**2. Credentials File Missing**
```bash
# Check if file exists
sudo ls -la /etc/cloudflared/*.json

# Fix: Re-create tunnel or copy credentials
```

**3. Firewall Blocking**
```bash
# Check UFW allows outbound
sudo ufw status

# Tunnel needs outbound 443, 7844
sudo ufw allow out 443/tcp
sudo ufw allow out 7844/udp
```

### Tunnel Disconnects Frequently

**Check:**
```bash
# View disconnect errors
sudo journalctl -u cloudflared --since "1 hour ago" | grep -i error
```

**Possible Causes:**
- Network instability
- Server overload
- cloudflared outdated

**Solutions:**
```bash
# Update cloudflared
sudo apt update
sudo apt upgrade cloudflared
sudo systemctl restart cloudflared

# Reduce protocol to HTTP/2 (from QUIC)
# Edit /etc/cloudflared/config.yml:
protocol: http2
```

---

## SSH via Tunnel Issues

### Can't SSH via Tunnel

**Common Mistake**: Trying to use regular SSH

❌ **This doesn't work**:
```bash
ssh sysadmin@yourdomain.com
ssh sysadmin@ssh.yourdomain.com
```

SSH via Cloudflare Tunnel is **NOT automatic**. You MUST use ProxyCommand.

✅ **You MUST use one of these methods**:

**Method 1: Full command** (tedious):
```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.yourdomain.com" sysadmin@ssh.yourdomain.com
```

**Method 2: SSH config** (recommended):

Quick setup (recommended):
```bash
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com sysadmin

# Default alias is the first label of your domain:
ssh yourdomain
```

Edit `~/.ssh/config`:
```
Host myserver
  HostName ssh.yourdomain.com
  User sysadmin
  ProxyCommand cloudflared access ssh --hostname ssh.yourdomain.com
  IdentityFile ~/.ssh/id_ed25519
```

Then use: `ssh myserver`

---

### "cloudflared: command not found"

**On LOCAL machine** (not server):

```bash
# Recommended (installs cloudflared + configures SSH for tunnel access)
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com sysadmin

# Manual install (if you prefer)
# macOS: brew install cloudflared
# Debian/Ubuntu: install via https://pkg.cloudflare.com/cloudflared
# Other Linux: use Cloudflare’s official releases (verify source)
```

**Verify**:
```bash
cloudflared --version
which cloudflared
```

---

### "Connection refused" or timeout

**Check tunnel on SERVER**:
```bash
# If you still have direct SSH access:
ssh root@<server-ip>

# Check tunnel status
sudo systemctl status cloudflared
sudo journalctl -u cloudflared --since "5 minutes ago"
```

**Check DNS resolves**:
```bash
dig ssh.yourdomain.com
# Should show CNAME to <UUID>.cfargotunnel.com
```

**Check tunnel config on server**:
```bash
sudo cat /etc/cloudflared/config.yml
# Verify:
# - Correct tunnel UUID
# - ssh.yourdomain.com hostname present
# - service: ssh://localhost:22
```

---

### SSH works but can't use sudo

**Check user permissions**:
```bash
# On server
groups sysadmin
# Should include "sudo"

# If not, add to sudo group
sudo usermod -aG sudo sysadmin
```

---

### Lost SSH access entirely

**Recovery options**:

1. **Cloud provider console** (VNC/Serial):
   - Access web console from Hetzner/DigitalOcean/etc.
   - Login as root
   - Check tunnel: `systemctl status cloudflared`
   - Re-enable direct SSH temporarily: `ufw allow OpenSSH`

2. **Restart tunnel service**:
   ```bash
   sudo systemctl restart cloudflared
   sudo journalctl -u cloudflared -f
   ```

3. **Verify tunnel config**:
   ```bash
   sudo nano /etc/cloudflared/config.yml
   # Check tunnel UUID matches
   # Check credentials file exists
   sudo cloudflared tunnel --config /etc/cloudflared/config.yml run
   ```

---

## DNS & Networking

### DNS Not Resolving

**Diagnosis:**
```bash
# From your workstation
dig staging-app.yourdomain.com
nslookup staging-app.yourdomain.com

# Should return Cloudflare IPs
```

**Solutions:**

**1. Nameservers Not Updated**
- Check domain registrar
- Ensure using Cloudflare nameservers
- Wait up to 48 hours for propagation

**2. DNS Record Missing**
```bash
# List tunnel routes
cloudflared tunnel route dns

# Add missing route
cloudflared tunnel route dns production-tunnel staging-app.yourdomain.com
```

**3. Proxy Disabled**
- Check Cloudflare Dashboard → DNS
- Ensure orange cloud (proxied) is enabled
- Gray cloud = direct connection (bypass tunnel)

### Can't SSH via Tunnel

**Diagnosis:**
```bash
# From workstation
ssh -v myserver
# Look for errors in verbose output
```

**Common Issues:**

**1. cloudflared Not Installed Locally**
```bash
# Recommended (installs cloudflared + configures SSH)
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com sysadmin

# Manual:
# macOS: brew install cloudflared
# Debian/Ubuntu: install via https://pkg.cloudflare.com/cloudflared
```

**2. SSH Config Wrong**
```bash
# Check ~/.ssh/config
cat ~/.ssh/config

# Should have:
ProxyCommand cloudflared access ssh --hostname %h
```

**3. SSH Not Routed Through Tunnel**
```bash
# On server, check config
sudo cat /etc/cloudflared/config.yml

# Should have:
ingress:
  - hostname: ssh.yourdomain.com
    service: ssh://localhost:22
```

---

## Docker & Resources

### High Memory Usage

**Diagnosis:**
```bash
# Find memory hogs
sudo docker stats --no-stream | sort -k4 -h
```

**Solutions:**
```bash
# 1. Restart container
sudo docker compose restart app

# 2. Reduce memory limit (forces container to use less)
# In compose.yml:
deploy:
  resources:
    limits:
      memory: 256M  # Reduce from 512M

# 3. Optimize application code
```

### Disk Space Full

**Diagnosis:**
```bash
df -h
sudo docker system df -v
du -sh /var/lib/docker/*
```

**Solutions:**
```bash
# Clean unused resources
sudo docker system prune -a --volumes
# WARNING: Removes ALL unused containers, images, volumes

# Safer: Clean selectively
sudo docker image prune -a  # Unused images only
sudo docker volume prune    # Unused volumes only

# Check specific volumes
sudo docker volume ls
sudo docker volume rm <volume_name>
```

### Build Failures

**Diagnosis:**
```bash
sudo docker compose build
# Look for error messages
```

**Common Issues:**

**1. Dockerfile Syntax Error**
```dockerfile
# Fix syntax errors
# Ensure proper formatting
```

**2. npm install Fails**
```bash
# Clear npm cache
sudo docker compose build --no-cache
```

**3. Permission Denied**
```bash
# Check file permissions
ls -la Dockerfile

# Fix
chmod 644 Dockerfile
```

---

## Caddy Issues

### Caddy Won't Start

**Diagnosis:**
```bash
cd infra/reverse-proxy
sudo docker compose logs caddy
sudo docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
```

**Common Issues:**

**1. Caddyfile Syntax Error**
```bash
# Test config
sudo docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile

# Fix syntax and restart
sudo docker compose restart caddy
```

**2. Port 80 Already in Use**
```bash
# Find what's using port 80
sudo netstat -tulpn | grep :80

# Stop conflicting service
sudo systemctl stop apache2
```

### Routes Not Working

**Check:**
```bash
# View Caddy logs
sudo docker compose logs caddy --tail=100

# Test if Caddy can reach app
sudo docker compose exec caddy wget -O- http://app-staging:80
```

**Solutions:**
```bash
# 1. Verify app is on correct network
sudo docker inspect app-staging | grep NetworkMode

# 2. Update Caddyfile
nano Caddyfile

# 3. Restart Caddy
sudo docker compose restart caddy
```

---

## Performance Issues

### Slow Response Times

**Diagnosis:**
```bash
# Time request
time curl https://staging-app.yourdomain.com

# Check app metrics
sudo docker stats app-staging

# Check Caddy logs for slow requests
sudo docker compose exec caddy tail -f /data/logs/staging-access.log
```

**Solutions:**
1. Enable Cloudflare caching
2. Optimize application code
3. Add more CPU/RAM to container
4. Use connection pooling for databases

### High CPU Usage

**Find culprit:**
```bash
sudo docker stats --no-stream | sort -k3 -h
```

**Solutions:**
```bash
# Limit CPU
# In compose.yml:
deploy:
  resources:
    limits:
      cpus: '0.5'  # Limit to half a CPU
```

---

## Emergency Procedures

### Complete Outage

**Steps:**
```bash
# 1. Check tunnel
sudo systemctl restart cloudflared

# 2. Check Caddy
cd infra/reverse-proxy
sudo docker compose restart

# 3. Check all apps
sudo docker ps -a
sudo docker compose --compatibility up -d  # In each app directory

# 4. Check firewall
sudo ufw status
```

### Suspected Security Breach

**Steps:**
```bash
# 1. Block suspicious IP
sudo ufw deny from <ip-address>

# 2. Review logs
sudo journalctl --since "1 hour ago" | grep <ip-address>

# 3. Check for unauthorized containers
sudo docker ps -a

# 4. Rotate all secrets
# Update .env files in all apps

# 5. Review user access
who
sudo tail -50 /var/log/auth.log
```

---

## Getting More Help

### Enable Debug Logging

**Tunnel:**
```yaml
# /etc/cloudflared/config.yml
loglevel: debug
```

**Caddy:**
```caddyfile
# Caddyfile
{
  debug
}
```

**Docker:**
```bash
sudo docker compose logs -f --tail=500
```

### Collect Diagnostic Info

```bash
# System info
uname -a
lsb_release -a
df -h
free -h

# Docker info
docker --version
sudo docker compose version
sudo docker ps -a
sudo docker network ls

# Service status
sudo systemctl status cloudflared
sudo systemctl status docker
sudo ufw status verbose

# Logs
sudo journalctl -u cloudflared --since "1 hour ago" > tunnel.log
sudo docker compose logs > app.log
```

---

## Common Error Messages

### "tunnel credentials file not found"
**Fix:** Recreate tunnel or copy credentials file

### "port is already allocated"
**Fix:** Change port or stop conflicting service

### "network not found"
**Fix:** Run `sudo ./scripts/create-networks.sh`

### "no such file or directory"
**Fix:** Create missing directories or fix volume mounts

### "permission denied"
**Fix:** Check file ownership and permissions

---

## Still Need Help?

1. Check [Architecture Overview](04-architecture.md)
2. Review [RUNBOOK.md](../RUNBOOK.md)
3. Re-read [SETUP.md](../SETUP.md)
4. Check [Cloudflare Tunnel Setup](../infra/cloudflared/tunnel-setup.md)
5. Open an issue on GitHub
