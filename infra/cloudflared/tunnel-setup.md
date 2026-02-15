# Cloudflare Tunnel Setup Guide

Complete guide for setting up Cloudflare Tunnel (cloudflared) on Ubuntu.

## Prerequisites

- ✅ Domain with nameservers pointing to Cloudflare
- ✅ Cloudflare account (free tier)
- ✅ Ubuntu server with sudo access

---

## 1. Install cloudflared (Latest Method - 2024/2025)

### Option A: APT Repository (Recommended)

```bash
# Create keyrings directory
sudo mkdir -p --mode=0755 /usr/share/keyrings

# Add Cloudflare GPG key
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

# Add Cloudflare apt repository
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list

# Update and install
sudo apt update
sudo apt install -y cloudflared

# Verify installation
cloudflared --version
```

### Option B: Direct Binary Download

```bash
# Download latest release
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared

# Make executable
chmod +x cloudflared

# Move to system path
sudo mv cloudflared /usr/local/bin/

# Verify
cloudflared --version
```

---

## 2. Authenticate with Cloudflare

```bash
# This opens a browser for authentication
cloudflared tunnel login
```

This creates a certificate at: `~/.cloudflared/cert.pem`

---

## 3. Create Tunnel

```bash
# Create a new tunnel
cloudflared tunnel create production-tunnel

# ⚠️ IMPORTANT: Save the Tunnel UUID shown in the output!
# Example output:
# Created tunnel production-tunnel with id: a9ae4e2e-f936-47a8-b3ec-aadcef3c50d0
```

This creates a credentials file at:
`~/.cloudflared/<TUNNEL_UUID>.json`

---

## 4. Configure Tunnel

```bash
# Copy example config
sudo cp config.yml.example /etc/cloudflared/config.yml

# Edit configuration
sudo nano /etc/cloudflared/config.yml
```

**Replace these placeholders:**
- `YOUR_TUNNEL_UUID` → Your actual tunnel UUID
- `yourdomain.com` → Your actual domain

**Example configuration:**

```yaml
tunnel: a9ae4e2e-f936-47a8-b3ec-aadcef3c50d0
credentials-file: /etc/cloudflared/a9ae4e2e-f936-47a8-b3ec-aadcef3c50d0.json

ingress:
  - hostname: ssh.trenkwalder.digital
    service: ssh://localhost:22

  - service: http://localhost:80

protocol: quic
loglevel: info
```

---

## 5. Route DNS Records

Create DNS records pointing to your tunnel. You can do this via CLI or Dashboard.

### Method A: CLI (Recommended)

```bash
# Route SSH subdomain
cloudflared tunnel route dns production-tunnel ssh.yourdomain.com

# Route root domain
cloudflared tunnel route dns production-tunnel yourdomain.com

# Route www subdomain
cloudflared tunnel route dns production-tunnel www.yourdomain.com

# Route other subdomains as needed
# cloudflared tunnel route dns production-tunnel staging-app.yourdomain.com
```

**What this does:**
- Creates CNAME records in Cloudflare DNS
- Points domains → `<TUNNEL_UUID>.cfargotunnel.com`
- Automatically enables proxy (orange cloud ✅)

### Method B: Cloudflare Dashboard

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. Select your domain
3. Navigate to **DNS** → **Records**
4. Click **Add record**
5. Configure:
   - **Type**: CNAME
   - **Name**: `ssh` (or `@` for root, `www` for www subdomain)
   - **Target**: `<YOUR_TUNNEL_UUID>.cfargotunnel.com`
   - **Proxy status**: Proxied (orange cloud ✅)
   - **TTL**: Auto

6. Click **Save**

Repeat for each subdomain you want to route.

### Verify DNS Records

```bash
# Check if DNS resolves
dig ssh.yourdomain.com
dig yourdomain.com
dig www.yourdomain.com

# Should show CNAME pointing to <UUID>.cfargotunnel.com
```

**Common Issues:**
- Takes 1-2 minutes for DNS propagation
- Ensure orange cloud (Proxied) is enabled, not gray (DNS only)
- Clear browser cache if site doesn't load immediately

---

## 6. Start Tunnel as systemd Service

```bash
# Install as system service
sudo cloudflared service install

# Enable to start on boot
sudo systemctl enable cloudflared

# Start service
sudo systemctl start cloudflared

# Check status
sudo systemctl status cloudflared

# View logs
sudo journalctl -u cloudflared -f
```

---

## 7. Configure Cloudflare Dashboard

### A. SSL/TLS Settings

Go to: `SSL/TLS` → `Overview`

**Set encryption mode: Full**
- Recommended default (avoids "Flexible" downgrade footguns)
- Cloudflare Tunnel is encrypted; Caddy can still run HTTP on `localhost:80`

**Enable these:**
- ✅ TLS 1.3
- ✅ Automatic HTTPS Rewrites
- ✅ Always Use HTTPS
- ✅ Opportunistic Encryption

**Set minimum TLS version: 1.2**

### B. SSL/TLS Edge Certificates

Go to: `SSL/TLS` → `Edge Certificates`

**Create wildcard certificate:**
- *.yourdomain.com
- yourdomain.com

> **Important:** Free tier wildcards don't support multi-level subdomains.
> ❌ `something.subdomain.domain.com`
> ✅ `staging-app.domain.com`

### C. DNS Records

Go to: `DNS` → `Records`

Your tunnel should create these automatically:

```
Type    Name                Value                           Proxy Status
CNAME   ssh                 <UUID>.cfargotunnel.com        Proxied
CNAME   *                   <UUID>.cfargotunnel.com        Proxied (optional)
```

---

## 8. Test Tunnel

### Test HTTP Traffic

```bash
# Should show HTML from Caddy
curl https://staging-app.yourdomain.com
```

### Test SSH via Tunnel

#### Reality Check: SSH Config is ESSENTIAL!

❌ **This will NOT work** (tunnel is not automatic):
```bash
ssh sysadmin@yourdomain.com
ssh sysadmin@ssh.yourdomain.com
```

✅ **This works** (but tedious to type every time):
```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname ssh.yourdomain.com" sysadmin@ssh.yourdomain.com
```

✅ **Best solution** (configure once, use short alias):

#### Install cloudflared on Your Local Machine

**Debian/Ubuntu:**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb
cloudflared --version
```

**macOS:**
```bash
brew install cloudflared
```

**Other Linux:**
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared
chmod +x cloudflared
sudo mv cloudflared /usr/local/bin/
```

#### Quick Setup Script (Recommended)

This blueprint ships a helper that installs `cloudflared` (if needed) and writes `~/.ssh/config` for you:

```bash
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/main/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com sysadmin

# Default alias is the first label of your domain:
ssh yourdomain
```

#### Configure SSH Config (ESSENTIAL)

Edit `~/.ssh/config`:

```bash
nano ~/.ssh/config
```

Add configuration (replace with your domain/username):

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

**Set permissions:**
```bash
chmod 600 ~/.ssh/config
```

#### Connect Using Alias

Now you can use short commands:

```bash
# Connect as sysadmin
ssh myserver

# Connect as appmgr
ssh myserver-app

# File transfers work too
scp file.txt myserver:/tmp/
```

**What happens behind the scenes:**
1. SSH reads `~/.ssh/config`
2. Finds the ProxyCommand
3. Runs cloudflared to establish tunnel
4. Routes SSH traffic through Cloudflare
5. Connects to your server

Without SSH config, you'd need to type the full ProxyCommand every time!

---

## 9. Firewall Configuration

Now that tunnel is working, lock down inbound ports (tunnel-only):

```bash
# With Cloudflare Tunnel you do NOT need inbound 80/443 at all.
# All HTTP traffic arrives over the tunnel to localhost.
sudo ufw deny 80/tcp
sudo ufw deny 443/tcp

# CRITICAL: Remove SSH from public internet (tunnel handles it now)
sudo ufw delete allow OpenSSH
sudo ufw deny 22/tcp

# Verify - port 22 should NOT be open
sudo ufw status verbose
```

---

## Troubleshooting

### Tunnel not connecting

```bash
# Check service status
sudo systemctl status cloudflared

# View logs
sudo journalctl -u cloudflared -f

# Test config manually
cloudflared tunnel --config /etc/cloudflared/config.yml run
```

### DNS not resolving

```bash
# List tunnel routes
cloudflared tunnel route dns

# Check Cloudflare DNS dashboard
# Ensure CNAME records exist
```

### SSH not working

```bash
# Check if tunnel service is running
sudo systemctl status cloudflared

# Test SSH locally first
ssh -v sysadmin@localhost

# Check cloudflared client version (must be recent)
cloudflared --version
```

### 502 Bad Gateway

- Check if Caddy is running: `sudo docker compose ps`
- Check Caddy logs: `sudo docker compose logs caddy`
- Verify tunnel points to `http://localhost:80`

---

## Maintenance

### Update cloudflared

```bash
# If installed via apt
sudo apt update
sudo apt upgrade cloudflared

# Restart service
sudo systemctl restart cloudflared
```

### View Connected Clients

Cloudflare Dashboard → Zero Trust → Networks → Tunnels

### Rotate Credentials

```bash
# Create new tunnel
cloudflared tunnel create new-tunnel

# Update config with new UUID
sudo nano /etc/cloudflared/config.yml

# Restart service
sudo systemctl restart cloudflared

# Delete old tunnel
cloudflared tunnel delete old-tunnel
```

---

## Security Notes

✅ **Tunnel traffic is encrypted** (TLS 1.3)
✅ **No inbound ports** required (outbound only: 443, 7844)
✅ **Zero Trust** - SSH not exposed to public internet
✅ **Free tier** includes DDoS protection, CDN, WAF

---

## References

- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [cloudflared GitHub](https://github.com/cloudflare/cloudflared)
- [Tunnel Changelog](https://developers.cloudflare.com/cloudflare-one/changelog/tunnel/)
