# Complete Setup Guide

Step-by-step guide to deploy your production-ready hosting blueprint from scratch.

**Time:** ~45 minutes | **Difficulty:** Intermediate

---

## Prerequisites Checklist

Before starting, ensure you have:

- [ ] Ubuntu 22.04 or 24.04 LTS VM (4GB RAM minimum, 40GB disk minimum)
- [ ] Root/sudo access to the VM
- [ ] Domain name
- [ ] Cloudflare account (free tier)
- [ ] Domain nameservers pointed to Cloudflare
- [ ] SSH access to VM from your workstation

---

## Directory Structure Overview

This setup uses two separate directory paths:

| Path | Purpose |
|------|---------|
| `/opt/hosting-blueprint` | Repository clone with scripts, configs, templates |
| `/srv/apps/{dev,staging,production}` | Deployed applications (where CI/CD deploys to) |

This separation keeps the infrastructure code separate from deployed applications.

---

## Phase 1: Initial VM Setup (10 minutes)

### 1.1 Connect to Your VM

```bash
# Connect as root or a user with sudo access
ssh root@your-server-ip
```

### 1.2 Clone This Repository

```bash
# Install git if needed
apt update && apt install -y git

# Clone repository
git clone <your-repo-url> /opt/hosting-blueprint
cd /opt/hosting-blueprint
```

### 1.3 Run Automated Setup

```bash
# Make scripts executable
chmod +x scripts/*.sh
chmod +x scripts/**/*.sh

# (Optional) Preview what will be changed without executing
sudo ./scripts/setup-vm.sh --dry-run

# Run initial setup (creates users, hardens SSH, installs Docker)
sudo ./scripts/setup-vm.sh
```

**What this does:**
- Creates `sysadmin` (sudo) and `appmgr` (no sudo) users
- Hardens SSH configuration (key-only auth, strong ciphers)
- Hardens kernel parameters (sysctl settings)
- Enables UFW firewall (temporarily allows SSH)
- Installs Docker + Compose v2 with security defaults
- Configures fail2ban (SSH brute-force protection)
- Configures auditd (security event logging)
- Creates deployment directories at `/srv/apps/{dev,staging,production}`
- Installs systemd service for Docker Compose auto-start on boot
- Configures automatic security updates

**⚠️ IMPORTANT:** The script will ask for SSH public keys. Have them ready or add them manually after.

### 1.4 Test SSH Access

```bash
# From your workstation (new terminal)
ssh sysadmin@your-server-ip

# If successful, reload SSH on the server
sudo systemctl reload sshd
```

✅ **Checkpoint:** You can now SSH as `sysadmin` without password

---

## Phase 2: Cloudflare Configuration (15 minutes)

### 2.1 Configure DNS in Cloudflare

1. Log into [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Select your domain
3. Go to **DNS** → **Records**
4. Verify nameservers are pointing to Cloudflare

### 2.2 Configure SSL/TLS Settings

**SSL/TLS** → **Overview**:
- Encryption mode: **Flexible** (or **Full** - see note below)
- TLS 1.3: **On**
- Automatic HTTPS Rewrites: **On**
- Always Use HTTPS: **On**
- Opportunistic Encryption: **On**
- Minimum TLS Version: **1.2**

> **Note on Encryption Mode:** "Flexible" works because Cloudflare Tunnel creates its own encrypted connection to your origin - traffic never travels unencrypted over the internet. However, if you prefer explicit clarity or might later expose services directly, use "Full" mode instead. The tunnel's internal HTTP connection (localhost:80) is already secure within the encrypted tunnel.

**SSL/TLS** → **Edge Certificates**:
- Create certificate for:
  - `*.yourdomain.com`
  - `yourdomain.com`

### 2.3 Install cloudflared

```bash
# On your server
sudo ./scripts/install-cloudflared.sh

# Verify installation
cloudflared --version
```

### 2.4 Authenticate with Cloudflare

```bash
# This opens a browser for authentication
cloudflared tunnel login
```

Creates: `~/.cloudflared/cert.pem`

### 2.5 Create Tunnel

```bash
# Create tunnel and save the UUID shown!
cloudflared tunnel create production-tunnel

# Example output:
# Created tunnel production-tunnel with id: a9ae4e2e-f936-47a8-b3ec-aadcef3c50d0
```

**⚠️ SAVE THE TUNNEL UUID!** You'll need it in the next step.

### 2.6 Configure Tunnel

```bash
# Copy example config
sudo cp infra/cloudflared/config.yml.example /etc/cloudflared/config.yml

# Edit configuration
sudo nano /etc/cloudflared/config.yml
```

Replace:
- `YOUR_TUNNEL_UUID` → Your actual tunnel UUID
- `yourdomain.com` → Your actual domain

```yaml
tunnel: a9ae4e2e-f936-47a8-b3ec-aadcef3c50d0
credentials-file: /root/.cloudflared/a9ae4e2e-f936-47a8-b3ec-aadcef3c50d0.json

ingress:
  - hostname: ssh.yourdomain.com
    service: ssh://localhost:22
  - service: http://localhost:80
```

### 2.7 Route DNS and Start Tunnel

```bash
# Create DNS record for SSH
cloudflared tunnel route dns production-tunnel ssh.yourdomain.com

# Install as systemd service
sudo cloudflared service install

# Enable and start
sudo systemctl enable cloudflared
sudo systemctl start cloudflared

# Check status
sudo systemctl status cloudflared

# View logs
sudo journalctl -u cloudflared -f
```

✅ **Checkpoint:** Tunnel is running and connected to Cloudflare

### 2.8 Lock Down Firewall

Now that tunnel is working, restrict access to Cloudflare IPs only:

```bash
# Download Cloudflare IP ranges
curl -s https://www.cloudflare.com/ips-v4 -o /tmp/cf_ips_v4
curl -s https://www.cloudflare.com/ips-v6 -o /tmp/cf_ips_v6

# Allow only Cloudflare IPs to web ports
while read ip; do sudo ufw allow from $ip to any port 80,443 proto tcp; done < /tmp/cf_ips_v4
while read ip; do sudo ufw allow from $ip to any port 80,443 proto tcp; done < /tmp/cf_ips_v6

# Remove public SSH access (tunnel handles it now)
sudo ufw delete allow OpenSSH

# Verify - port 22 should NOT be listed
sudo ufw status verbose
```

✅ **Checkpoint:** Firewall locked down, SSH only via tunnel

---

## Phase 3: Docker Infrastructure (10 minutes)

### 3.1 Create Docker Networks

```bash
# Create isolated networks for staging, production, monitoring
./scripts/create-networks.sh
```

Creates:
- `prod-web` - Production apps + Caddy
- `prod-backend` - Production databases (internal only)
- `staging-web` - Staging apps + Caddy
- `staging-backend` - Staging databases (internal only)
- `monitoring` - Netdata (optional)

### 3.2 Configure Reverse Proxy (Caddy)

```bash
cd infra/reverse-proxy

# Copy environment file
cp .env.example .env

# Edit with your domain
nano .env
```

Set:
```bash
DOMAIN=yourdomain.com
```

### 3.3 Update Caddyfile

```bash
nano Caddyfile
```

Replace all instances of `yourdomain.com` with your actual domain:
```bash
# Quick replace (macOS/Linux)
sed -i 's/yourdomain.com/yourREALdomain.com/g' Caddyfile
```

### 3.4 Deploy Caddy

```bash
# Start Caddy
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f caddy
```

✅ **Checkpoint:** Caddy is running and waiting for app traffic

---

## Phase 4: Deploy First Application (10 minutes)

### 4.1 Deploy Hello World Example

```bash
cd ../../apps/examples/hello-world

# Copy environment file
cp .env.example .env

# Configure for staging
nano .env
```

Set:
```bash
ENVIRONMENT=staging
DOCKER_NETWORK=staging-web
```

### 4.2 Start Application

```bash
# Deploy app
docker compose up -d

# Check status
docker compose ps

# View logs
docker compose logs -f
```

### 4.3 Add to Caddy

```bash
cd ../../../infra/reverse-proxy
nano Caddyfile
```

Update the staging block:
```caddyfile
http://staging-app.yourdomain.com {
  import security_headers
  reverse_proxy app-staging:80 {
    import proxy_headers
  }
  log {
    output file /data/logs/staging-access.log
    format json
  }
}
```

Restart Caddy:
```bash
docker compose restart caddy
```

### 4.4 Test Your App

```bash
# From anywhere
curl https://staging-app.yourdomain.com
```

**🎉 You should see the Hello World page!**

✅ **Checkpoint:** First app is live at `https://staging-app.yourdomain.com`

---

## Phase 5: SSH via Tunnel (⚠️  CRITICAL - Test Before Disabling Direct SSH!)

> **IMPORTANT**: Complete ALL steps in this phase BEFORE closing port 22 to public!

### 5.1 Install cloudflared on Your Workstation

**Debian/Ubuntu (Local Machine):**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
cloudflared --version
rm cloudflared.deb
```

**macOS:**
```bash
brew install cloudflared
```

**Arch Linux:**
```bash
sudo pacman -S cloudflared
```

**Other Linux:**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/
```

**Windows:**
Download from: https://github.com/cloudflare/cloudflared/releases

### 5.2 Test Tunnel SSH (Full Command)

**⚠️  Reality Check**: SSH via tunnel does NOT work with regular commands!

❌ **This will NOT work**:
```bash
ssh sysadmin@yourdomain.com          # Tunnel is NOT automatic!
ssh sysadmin@ssh.yourdomain.com      # Still won't work!
```

✅ **This works, but is tedious**:
```bash
# Replace with YOUR domain and username
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.yourdomain.com" sysadmin@ssh.yourdomain.com
```

**Try this now** to verify tunnel SSH works. If successful, proceed to configure SSH config.

### 5.3 Configure SSH Config (ESSENTIAL for Convenience)

To avoid typing that long ProxyCommand every time, configure SSH:

**Edit config file**:
```bash
nano ~/.ssh/config
```

**Add this configuration** (replace with your domain and username):
```
# Production server via Cloudflare Tunnel
Host myserver
  HostName ssh.yourdomain.com
  User sysadmin
  ProxyCommand cloudflared access ssh --hostname ssh.yourdomain.com
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 60
  ServerAliveCountMax 3

# App manager user
Host myserver-app
  HostName ssh.yourdomain.com
  User appmgr
  ProxyCommand cloudflared access ssh --hostname ssh.yourdomain.com
  IdentityFile ~/.ssh/id_ed25519
```

**Set permissions**:
```bash
chmod 600 ~/.ssh/config
```

**Now test with the alias**:
```bash
ssh myserver
# Should connect successfully!
```

### 5.4 Verify Tunnel SSH Works (Critical Checklist)

You can use the automated verification script:
```bash
# From your local machine (where you have cloudflared installed)
./scripts/verify-tunnel-ssh.sh ssh.yourdomain.com sysadmin
```

Or manually test **ALL of these BEFORE closing port 22**:

```bash
# 1. Can connect
ssh myserver
# Should connect successfully ✓

# 2. Can run sudo
ssh myserver "sudo whoami"
# Should return "root" ✓

# 3. Can transfer files
echo "test" > /tmp/test.txt
scp /tmp/test.txt myserver:/tmp/
# Should succeed ✓

# 4. Connection is stable
ssh myserver "sleep 300 && echo 'Still connected after 5 minutes'"
# Should complete after 5 minutes ✓

# 5. Can reconnect after disconnect
ssh myserver "exit"
ssh myserver
# Should connect again ✓
```

**⚠️  DO NOT proceed to step 5.5 until ALL 5 tests pass!**

### 5.5 Disable Direct SSH Access (ONLY After All Tests Pass!)

Once tunnel SSH is proven working:

```bash
# Connect via tunnel
ssh myserver

# Get Cloudflare IP ranges
curl -s https://www.cloudflare.com/ips-v4 -o /tmp/cf_ips_v4
curl -s https://www.cloudflare.com/ips-v6 -o /tmp/cf_ips_v6

# Allow only Cloudflare IPs to web ports
while read ip; do sudo ufw allow from $ip to any port 80,443 proto tcp; done < /tmp/cf_ips_v4
while read ip; do sudo ufw allow from $ip to any port 80,443 proto tcp; done < /tmp/cf_ips_v6

# Remove public SSH access
sudo ufw delete allow OpenSSH
sudo ufw delete allow 22/tcp

# Verify - port 22 should NOT be listed
sudo ufw status verbose | grep 22
```

**Final test**:
```bash
# Disconnect
exit

# Reconnect via tunnel (should still work)
ssh myserver

# Verify port 22 is closed
sudo ufw status verbose
# Should NOT see any rule for port 22
```

✅ **Checkpoint:** Port 22 closed to public, SSH works via tunnel only

### 5.6 Emergency Recovery (If You Lose SSH Access)

**If tunnel SSH stops working**:

1. **Via Cloud Console** (Hetzner, DigitalOcean, etc.):
   - Access web console/VNC
   - Re-enable SSH: `sudo ufw allow OpenSSH`
   - Debug tunnel: `sudo systemctl status cloudflared`

2. **Restart tunnel service**:
   ```bash
   sudo systemctl restart cloudflared
   sudo journalctl -u cloudflared --since "5 minutes ago"
   ```

---

## Phase 6: Deploy Production App

### 6.1 Create Production App

```bash
# Copy hello-world for production
cd /opt/hosting-blueprint/apps/examples
cp -r hello-world hello-world-prod
cd hello-world-prod

# Configure for production
cp .env.example .env
nano .env
```

Set:
```bash
ENVIRONMENT=production
DOCKER_NETWORK=prod-web
```

### 6.2 Deploy

```bash
docker compose up -d
docker compose ps
```

### 6.3 Add to Caddy

```bash
cd ../../../infra/reverse-proxy
nano Caddyfile
```

Update production block:
```caddyfile
http://app.yourdomain.com {
  import security_headers
  reverse_proxy app-production:80 {
    import proxy_headers
  }
  log {
    output file /data/logs/production-access.log
    format json
  }
}
```

Restart Caddy:
```bash
docker compose restart caddy
```

### 6.4 Test Production

```bash
curl https://app.yourdomain.com
```

✅ **Checkpoint:** Production app live at `https://app.yourdomain.com`

---

## Phase 7: Deploy Your Own App

### 7.1 Copy Template

```bash
cd /opt/hosting-blueprint/apps
cp -r _template my-app
cd my-app
```

### 7.2 Configure

```bash
cp .env.example .env
nano .env
```

Set:
```bash
ENVIRONMENT=staging
APP_NAME=my-app
DOCKER_NETWORK=staging-web
APP_PORT=3000
NODE_ENV=production
```

### 7.3 Update compose.yml

```bash
nano compose.yml
```

Update:
- `image:` - Your Docker image
- `healthcheck:` - Your health endpoint
- Add any volumes, environment variables needed

### 7.4 Deploy

```bash
docker compose pull  # or docker compose build
docker compose up -d
```

### 7.5 Add to Caddy

```bash
cd ../../infra/reverse-proxy
nano Caddyfile
```

Add:
```caddyfile
http://staging-my-app.yourdomain.com {
  import security_headers
  reverse_proxy app-my-app:3000 {
    import proxy_headers
  }
}
```

Restart:
```bash
docker compose restart caddy
```

---

## Verification Checklist

After setup, verify everything works:

- [ ] Tunnel status: `sudo systemctl status cloudflared`
- [ ] Caddy status: `cd infra/reverse-proxy && docker compose ps`
- [ ] Apps running: `docker ps`
- [ ] Staging app: `curl https://staging-app.yourdomain.com`
- [ ] Production app: `curl https://app.yourdomain.com`
- [ ] SSH via tunnel: `ssh myserver`
- [ ] Firewall locked: `sudo ufw status` (no port 22)
- [ ] Docker networks: `docker network ls | grep -E "staging|prod"`

---

## Common Issues

### Tunnel not connecting

```bash
sudo journalctl -u cloudflared -f
# Check tunnel UUID in config matches created tunnel
```

### 502 Bad Gateway

```bash
# Check if Caddy is running
cd infra/reverse-proxy
docker compose ps
docker compose logs caddy

# Check if app is running
cd ../../apps/examples/hello-world
docker compose ps
```

### App container unhealthy

```bash
docker compose logs app
docker inspect app-staging | grep -A 10 Health
```

### DNS not resolving

- Check Cloudflare DNS dashboard
- Ensure CNAME records exist for subdomains
- Wait 1-2 minutes for DNS propagation

---

## Next Steps

1. **Add Monitoring** → See [docs/13-monitoring-with-netdata.md](docs/13-monitoring-with-netdata.md)
2. **Deploy More Apps** → Use `apps/_template/` as starting point
3. **Review Security** → See [docs/02-security-hardening.md](docs/02-security-hardening.md)
4. **Learn Operations** → Read [RUNBOOK.md](RUNBOOK.md)

---

## Getting Help

- **Troubleshooting:** [docs/05-troubleshooting.md](docs/05-troubleshooting.md)
- **Architecture:** [docs/04-architecture.md](docs/04-architecture.md)
- **Cloudflare Tunnel:** [infra/cloudflared/tunnel-setup.md](infra/cloudflared/tunnel-setup.md)

**Congratulations! Your production-ready hosting blueprint is complete! 🎉**
