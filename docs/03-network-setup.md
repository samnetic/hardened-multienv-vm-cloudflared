# Network Setup Guide

This guide covers the network architecture for the hardened multi-environment VPS, including Docker networks, firewall configuration, and Cloudflare Tunnel integration.

---

## Overview

The network setup follows a zero-trust architecture where:
- **No ports are exposed** directly to the internet
- All traffic flows through **Cloudflare Tunnel** (outbound connection)
- Docker networks provide **environment isolation**
- UFW firewall provides **defense in depth**

```
Internet → Cloudflare CDN → Encrypted Tunnel → VM → Caddy → Docker Networks → Apps
                                 ↑
                          (outbound only)
```

---

## Docker Networks

### Network Architecture

| Network | Type | Environment | Purpose |
|---------|------|-------------|---------|
| `hosting-caddy-origin` | internal | Shared | Reverse proxy origin enforcement (tunnel-only) |
| `dev-web` | bridge | Dev | Apps accessible via Caddy |
| `dev-backend` | bridge | Dev | DBs accessible from host (for local development) |
| `staging-web` | bridge | Staging | Apps accessible via Caddy |
| `staging-backend` | internal | Staging | DBs isolated (not accessible from host) |
| `prod-web` | bridge | Production | Apps accessible via Caddy |
| `prod-backend` | internal | Production | DBs isolated (most secure) |
| `monitoring` | bridge | Shared | Optional Netdata monitoring |

### Network Types

**Bridge Networks** (`bridge`)
- Containers can communicate with each other
- Containers can be accessed from the host
- Used for web-facing services

**Internal Networks** (`internal`)
- Containers can communicate with each other on that network
- Containers do not have external routing (no internet access by default)
- Used for databases in staging/production and for `hosting-caddy-origin`
- Note: don’t treat `internal` as a complete host firewall; keep UFW + “no published ports”

### Creating Networks

Run the network creation script:

```bash
sudo ./scripts/create-networks.sh
```

This creates all networks with proper isolation settings.

### Manual Network Commands

```bash
# List all networks
sudo docker network ls

# Inspect a network
sudo docker network inspect prod-backend

# Create a bridge network
sudo docker network create my-network

# Create an internal network (isolated)
sudo docker network create my-network --internal

# Remove a network
sudo docker network rm my-network
```

---

## Connecting Services to Networks

### In Docker Compose

```yaml
services:
  app:
    image: myapp:latest
    networks:
      - staging-web

  database:
    image: postgres:16
    networks:
      - staging-backend

networks:
  staging-web:
    external: true
  staging-backend:
    external: true
```

**Key Points:**
- Use `external: true` for pre-created networks
- Web services connect to `*-web` networks
- Databases connect to `*-backend` networks
- Multi-network services connect to both as needed

### Cross-Environment Communication

Services should generally **not** communicate across environments. However, if needed (e.g., shared database):

```yaml
services:
  shared-db:
    networks:
      - staging-backend
      - prod-backend  # Not recommended for production
```

---

## Firewall (UFW)

### Default Policy

```bash
# Default deny incoming, allow outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

### Initial Setup Rules

During setup, SSH is temporarily allowed:

```bash
# Temporary (remove after tunnel setup)
sudo ufw allow OpenSSH comment "SSH - REMOVE AFTER TUNNEL SETUP"
sudo ufw limit OpenSSH comment "SSH rate limiting"
```

### After Cloudflare Tunnel Setup

Once the tunnel is working, remove direct SSH access:

```bash
# Remove direct SSH access
sudo ufw delete allow OpenSSH
sudo ufw delete limit OpenSSH
```

### Check Firewall Status

```bash
sudo ufw status verbose
```

Expected output after hardening:
```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
```

---

## Cloudflare Tunnel

### How It Works

1. `cloudflared` daemon runs on your VM
2. It establishes an **outbound** encrypted connection to Cloudflare
3. Cloudflare routes traffic to your VM through this tunnel
4. No incoming ports needed on your VM

### Traffic Flow

```
User Request
    ↓
Cloudflare Edge (SSL termination, DDoS protection, WAF)
    ↓
Encrypted Tunnel (QUIC protocol, outbound from VM)
    ↓
cloudflared daemon (localhost)
    ↓
Caddy reverse proxy (localhost:80)
    ↓
Docker container (via network)
```

### Tunnel Configuration

See `infra/cloudflared/config.yml.example`:

```yaml
tunnel: YOUR_TUNNEL_UUID
credentials-file: /etc/cloudflared/YOUR_TUNNEL_UUID.json

ingress:
  # SSH access
  - hostname: ssh.yourdomain.com
    service: ssh://localhost:22

  # Web apps (via Caddy)
  - hostname: app.yourdomain.com
    service: http://localhost:80
  - hostname: staging-app.yourdomain.com
    service: http://localhost:80
  - hostname: dev-app.yourdomain.com
    service: http://localhost:80

  # Catch-all (required)
  - service: http_status:404
```

### Testing Tunnel

```bash
# Check tunnel status
sudo systemctl status cloudflared

# Test connectivity
curl -I https://app.yourdomain.com

# View tunnel logs
sudo journalctl -u cloudflared -f
```

---

## Caddy Reverse Proxy

Caddy sits between the tunnel and your Docker containers:

```
cloudflared → Caddy (localhost:80) → Docker containers
```

### Routing by Subdomain

From `infra/reverse-proxy/Caddyfile`:

```caddyfile
# Production
app.yourdomain.com {
    reverse_proxy app-production:8080
}

# Staging
staging-app.yourdomain.com {
    reverse_proxy app-staging:8080
}

# Development
dev-app.yourdomain.com {
    reverse_proxy app-dev:8080
}
```

### Container Discovery

Caddy resolves container names via Docker's internal DNS when connected to the same network.

```yaml
# Caddy's compose.yml
services:
  caddy:
    networks:
      - staging-web
      - prod-web
```

---

## Security Considerations

### Internal Networks for Databases

**Always** put databases on internal networks:

```yaml
services:
  postgres:
    networks:
      - prod-backend  # Internal network only
```

This prevents:
- Direct access from host
- Access from other containers not on the network
- Accidental exposure

### Network Segmentation

| Environment | Can Access Internet? | Can Access Host? | Can Access Other Envs? |
|-------------|---------------------|------------------|------------------------|
| Dev | Yes | Yes (backend) | No |
| Staging | Yes | No (backend) | No |
| Production | Yes | No (backend) | No |

### Port Exposure

**Never** expose container ports to the host in production:

```yaml
# BAD - exposes port to all interfaces
services:
  app:
    ports:
      - "8080:8080"

# GOOD - no port exposure, Caddy routes via network
services:
  app:
    networks:
      - prod-web
    # No ports section
```

---

## Troubleshooting

### Network Not Found

```bash
# Error: network "prod-web" not found

# Solution: Create networks first
sudo ./scripts/create-networks.sh
```

### Container Can't Reach Another Container

```bash
# Check both containers are on the same network
sudo docker network inspect prod-web

# Verify container names
sudo docker ps --format "{{.Names}}"
```

### Can't Access Database from Host

For **staging/production**, this is by design (internal networks).

For **dev** environment, ensure you're using `dev-backend`:

```yaml
services:
  db:
    networks:
      - dev-backend
    ports:
      - "5432:5432"  # OK for dev only
```

### UFW Blocking Traffic

```bash
# Check UFW status
sudo ufw status verbose

# If needed, check logs
sudo tail -f /var/log/ufw.log
```

---

## Quick Reference

### Create All Networks

```bash
sudo ./scripts/create-networks.sh
```

### Check Network Status

```bash
# List networks
sudo docker network ls

# Show connected containers
sudo docker network inspect prod-web --format='{{range .Containers}}{{.Name}} {{end}}'
```

### Firewall Status

```bash
sudo ufw status verbose
```

### Tunnel Status

```bash
sudo systemctl status cloudflared
```

---

## Related Documentation

- [01-cloudflare-setup.md](01-cloudflare-setup.md) - Tunnel configuration
- [04-architecture.md](04-architecture.md) - Overall architecture
- [08-environment-tiers.md](08-environment-tiers.md) - Environment differences
