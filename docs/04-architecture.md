# Architecture Overview

How all components work together in this production hosting blueprint.

---

## High-Level Architecture

```
Internet Users
     │
     ↓
┌────────────────────────────────────────────┐
│          Cloudflare (Free Tier)           │
│  • SSL/TLS Termination (Flexible)          │
│  • DDoS Protection                         │
│  • CDN & Caching                           │
│  • WAF (Web Application Firewall)          │
└────────────┬───────────────────────────────┘
             │ HTTPS (443)
             │ Encrypted Tunnel
             ↓
┌────────────────────────────────────────────┐
│          Ubuntu VM (Your Server)           │
│                                            │
│  ┌─────────────────────────────────────┐  │
│  │   cloudflared (Tunnel Daemon)       │  │
│  │   • Outbound-only connections       │  │
│  │   • No open inbound ports           │  │
│  └──────────┬──────────────────────────┘  │
│             │ HTTP (localhost:80)         │
│             ↓                              │
│  ┌─────────────────────────────────────┐  │
│  │   Caddy (Reverse Proxy)             │  │
│  │   • HTTP routing by subdomain       │  │
│  │   • Security headers                │  │
│  │   • Access logging                  │  │
│  └────┬────────────────────────┬───────┘  │
│       │                        │           │
│  ┌────▼─────────┐      ┌──────▼────────┐  │
│  │ Docker:      │      │ Docker:       │  │
│  │ staging-web  │      │ prod-web      │  │
│  │              │      │               │  │
│  │ ┌──────────┐│      │┌──────────┐  │  │
│  │ │App (stg) ││      ││App (prod)│  │  │
│  │ └──────────┘│      │└──────────┘  │  │
│  └──────────────┘      └───────────────┘  │
│                                            │
│  Firewall (UFW):                          │
│  • Port 22: CLOSED                        │
│  • Port 80/443: Cloudflare IPs only       │
│  • Outbound: Allow all                    │
└────────────────────────────────────────────┘
```

---

## Component Breakdown

### 1. Cloudflare Layer

**Purpose:** Edge security and performance

**Functions:**
- SSL/TLS encryption (HTTPS)
- DDoS protection (automatic)
- CDN (content caching)
- WAF (blocks common attacks)
- DNS management

**Configuration:**
- Encryption mode: Flexible
- SSL/TLS: TLS 1.2+, Auto HTTPS
- DNS: CNAME records for subdomains

---

### 2. Cloudflare Tunnel (cloudflared)

**Purpose:** Secure connectivity without open ports

**How it works:**
1. Daemon runs on your server
2. Establishes outbound connection to Cloudflare
3. Cloudflare routes requests through this tunnel
4. No inbound firewall rules needed

**Benefits:**
- ✅ No exposed ports (no attack surface)
- ✅ SSH access via tunnel (zero trust)
- ✅ Automatic certificate management
- ✅ Free tier included

**Tunnel Config:**
```yaml
ingress:
  - hostname: ssh.domain.com
    service: ssh://localhost:22
  - service: http://localhost:80  # Everything else
```

**Protocols:**
- Prefers QUIC (UDP port 7844)
- Falls back to HTTP/2 (TCP port 443)

---

### 3. Caddy (Reverse Proxy)

**Purpose:** HTTP routing and security headers

**Why HTTP-only?**
- Cloudflare Tunnel handles HTTPS
- Simplifies certificate management
- Tunnel connection is already encrypted

**Routing Logic:**
```
staging-app.domain.com → app-staging:80
app.domain.com        → app-production:80
api.domain.com        → api-production:3000
```

**Security Features:**
- HSTS headers
- XSS protection
- MIME sniffing protection
- Clickjacking protection (X-Frame-Options)

---

### 4. Docker Networks

**Purpose:** Isolation between environments and services

```
staging-web      ←→  Staging apps + Caddy
staging-backend  ←→  Staging databases (internal only)

prod-web         ←→  Production apps + Caddy
prod-backend     ←→  Production databases (internal only)

monitoring       ←→  Netdata (optional)
```

**Isolation Benefits:**
- Staging can't access production
- Databases not exposed to internet
- Easier security boundaries

---

### 5. Application Containers

**Security Standards (2025):**
```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
cap_add:
  - NET_BIND_SERVICE  # Only if needed
read_only: true  # Where possible
```

**Resource Limits:**
```yaml
deploy:
  resources:
    limits:
      cpus: '1.0'
      memory: 512M
```

**Health Checks:**
```yaml
healthcheck:
  test: ["CMD", "wget", "http://localhost:3000/health"]
  interval: 30s
  timeout: 10s
```

---

## Traffic Flow

### Public Web Request

1. **User visits `https://app.domain.com`**
2. **DNS resolves** to Cloudflare IP (CNAME)
3. **Cloudflare CDN** checks cache
4. **Cloudflare Tunnel** forwards to server
5. **cloudflared** receives on localhost:80
6. **Caddy** routes based on `Host` header
7. **Docker app** processes request
8. **Response** back through same path

### SSH Connection (via Tunnel)

1. **User runs `ssh myserver`**
2. **SSH config** uses ProxyCommand with cloudflared
3. **Cloudflare Tunnel** routes SSH traffic
4. **cloudflared** forwards to localhost:22
5. **SSH daemon** authenticates (key-only)
6. **Encrypted SSH session** established

---

## Data Flow & Persistence

### Application Data

```
Container → Volume Mount → Host Filesystem
/app/data → ./data     → /opt/apps/my-app/data
```

**Backup Strategy:**
- Stop container
- Tar/zip `./data` directory
- Copy off-server
- Restart container

### Logs

**Caddy Logs:**
```
Container → Volume → Host
/data/logs → caddy_data volume → /var/lib/docker/volumes/
```

**App Logs:**
```
Container stdout → Docker JSON logs → /var/lib/docker/containers/
```

**Access:**
```bash
docker compose logs -f
docker compose logs --tail=100
```

---

## Security Boundaries

### Network Perimeter
- **External:** Cloudflare CDN (DDoS, WAF)
- **Internal:** UFW firewall (Cloudflare IPs only)

### Container Isolation
- **Kernel:** Linux namespaces, cgroups
- **Capabilities:** Dropped by default
- **Filesystem:** Read-only where possible

### User Separation
- **sysadmin:** System configuration (sudo)
- **appmgr:** Application deployment (no sudo)
- **Container user:** Non-root process

### Network Segmentation
- **staging-web:** Staging apps
- **prod-web:** Production apps
- **Backend networks:** Internal only (no internet)

---

## Failure Modes & Recovery

### Tunnel Disconnects
**Impact:** Site unreachable
**Auto-recovery:** cloudflared reconnects automatically
**Manual:** `sudo systemctl restart cloudflared`

### Caddy Crashes
**Impact:** All apps unreachable
**Auto-recovery:** Docker restart policy
**Manual:** `docker compose restart caddy`

### App Crashes
**Impact:** Single app unreachable
**Auto-recovery:** Docker restart + health checks
**Manual:** `docker compose restart app`

### Server Reboot
**Impact:** Temporary downtime
**Auto-recovery:**
- systemd starts cloudflared
- Docker starts containers (restart: unless-stopped)
**Downtime:** ~1-2 minutes

---

## Scaling Considerations

### Current Setup (Single VM)
- ✅ Multiple apps on one server
- ✅ Staging + production isolated
- ✅ Suitable for: 10-100 apps
- ❌ Single point of failure

### Scaling Up (Same VM)
- Add more CPU/RAM
- Update resource limits in compose files
- Vertical scaling

### Scaling Out (Multiple VMs)
**Option 1:** Dedicated servers per environment
- staging.domain.com → VM1
- app.domain.com → VM2

**Option 2:** Load balancing
- Multiple VMs behind Cloudflare Load Balancer
- Requires Cloudflare paid plan

**Option 3:** Kubernetes/Swarm
- Migrate to container orchestration
- Use this blueprint's configs as starting point

---

## Port Matrix

| Port | Service | Access | Purpose |
|------|---------|--------|---------|
| 22 | SSH | Closed to public | SSH (tunnel only) |
| 80 | Caddy | Cloudflare IPs only | HTTP routing |
| 443 | - | Not used | Tunnel handles HTTPS |
| 7844 | cloudflared | Outbound only | QUIC tunnel |

**All inbound traffic blocked except Cloudflare IPs to port 80.**

---

## Configuration Files

| File | Purpose | Location |
|------|---------|----------|
| `config.yml` | Tunnel config | `/etc/cloudflared/` |
| `Caddyfile` | Routing rules | `infra/reverse-proxy/` |
| `compose.yml` | App definition | `apps/*/` |
| `.env` | App secrets | `apps/*/.env` (gitignored) |
| `daemon.json` | Docker config | `/etc/docker/` |
| `sshd_config` | SSH hardening | `/etc/ssh/` |

---

## Monitoring Points

**Infrastructure:**
- Tunnel: `systemctl status cloudflared`
- Caddy: `docker compose ps`
- Firewall: `ufw status`

**Applications:**
- Containers: `docker ps`
- Logs: `docker compose logs`
- Health: `docker inspect <container> | grep Health`

**System:**
- Disk: `df -h`
- Memory: `free -h`
- CPU: `htop`

---

## Summary

This architecture provides:
✅ **Security** - Zero trust, encrypted tunnel, isolated networks
✅ **Simplicity** - Single VM, standard Docker
✅ **Reliability** - Auto-restart, health checks
✅ **Scalability** - Easy to add more apps
✅ **Cost** - Free tier Cloudflare + single VM
✅ **Maintainability** - Clear separation, standard tools

**Perfect for:**
- Small to medium teams
- 10-100 applications
- Staging + production on one VM
- Budget-conscious deployments
