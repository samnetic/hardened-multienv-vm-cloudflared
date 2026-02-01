# Hardened Multi-Environment VPS Template

> Single VM • Zero Open Ports • Three Environments • GitOps Ready

A **forkable template** for hosting Docker applications on a hardened Ubuntu server. Deploy with confidence using Cloudflare Tunnel for security, file-based secrets, and GitHub Actions for automated deployments.

**Fork this repo, customize, deploy.**

---

## What's in This Stack?

| Tool | What It Does | Why We Use It |
|------|--------------|---------------|
| **Cloudflared** | Creates encrypted tunnel to Cloudflare | Zero open ports, free SSL, DDoS protection |
| **Cloudflare Access** | Identity-based authentication | Login screen before admin panels (50 users free) |
| **Caddy** | Reverse proxy | Routes traffic to apps, adds security headers |
| **Docker Compose** | Runs your apps | Isolated containers, easy deployment |
| **UFW** | Firewall | Blocks all incoming traffic (tunnel only) |
| **fail2ban** | Intrusion prevention | Auto-bans brute force attempts |
| **auditd** | Security logging | Tracks who did what |
| **Netdata** | Monitoring (optional) | Real-time metrics, alerts, Docker stats |

### How It Works (Simple Version)

```
User → Cloudflare (SSL, DDoS protection) → Encrypted Tunnel → Your VM → Caddy → App
```

No ports open to the internet. Everything goes through Cloudflare's secure tunnel.

---

## Three Environments

| Environment | Purpose | Deployment | Database Access |
|-------------|---------|------------|-----------------|
| **Dev** | Playground, testing | Auto (feature/* branches) | From your local PC |
| **Staging** | Pre-production | Auto (main branch) | Internal only |
| **Production** | Live users | Manual (tags) | Internal only |

```
feature/xyz branch ──push──▶ DEV (auto)
           │
           └──PR merge──▶ main ──▶ STAGING (auto)
                           │
                           └──tag v1.x──▶ PRODUCTION (manual approval)
```

---

## 🚀 Universal Quickstart (5 Minutes)

Works on **any** cloud provider (Oracle, AWS, Hetzner, DigitalOcean, Vultr, Linode).

### Step 1: SSH into Your Fresh VM

```bash
# Oracle Cloud (default user: ubuntu)
ssh ubuntu@YOUR_VM_IP

# AWS (default user varies: ubuntu, ec2-user, admin)
ssh ubuntu@YOUR_VM_IP

# Other providers: Check their documentation for default user
```

### Step 2: Clone This Repo

```bash
# Install git (if not already installed)
sudo apt update && sudo apt install -y git

# Clone to the expected location
sudo git clone https://github.com/YOUR_USERNAME/hardened-multienv-vm-cloudflared.git /opt/hosting-blueprint

# Fix ownership (handles different cloud provider default users automatically)
sudo chown -R $(whoami):$(whoami) /opt/hosting-blueprint

# Navigate to repo
cd /opt/hosting-blueprint
```

### Step 3: Run Setup

```bash
# Interactive setup with automatic detection
sudo ./setup.sh
```

**The script will ask you:**
1. Domain name (e.g., `yourdomain.com`)
2. SSH public key for new admin user
3. Timezone
4. Whether to set up Cloudflare Tunnel

**It handles automatically:**
- ✅ Detects your cloud provider's default user
- ✅ Fixes git ownership issues
- ✅ Works on Oracle Cloud, AWS, DigitalOcean, etc.
- ✅ Handles ICMP/ping blocking (Oracle Cloud)

### Step 4: Manage Default User (Post-Setup)

After setup creates your new `sysadmin` and `appmgr` users:

```bash
# Manage the original default user (ubuntu, ec2-user, etc.)
sudo ./scripts/post-setup-user-cleanup.sh
```

**Options:**
- **Lock** (recommended) - Keeps console access, disables SSH
- **Delete** - More secure, removes console access (use with caution)
- **Keep Active** - Leave unchanged (not recommended)

---

## Quick Start (Detailed)

### Option 1: Interactive Setup (Recommended)

```bash
# Clone this repo
git clone <your-fork-url>
cd <repo-name>

# Run interactive setup
sudo ./setup.sh
```

The script will:
- Check your system (Ubuntu 22.04/24.04, RAM, disk)
- Ask for your domain and SSH keys
- Apply all hardening configurations
- Set up Docker and networks
- Guide you through Cloudflare Tunnel setup

### Option 2: Manual Setup

```bash
# 1. Preview what will be configured (optional)
sudo ./scripts/setup-vm.sh --dry-run

# 2. Run VM hardening
sudo ./scripts/setup-vm.sh

# 3. Create Docker networks
./scripts/create-networks.sh

# 4. Set up Cloudflare Tunnel
sudo ./scripts/install-cloudflared.sh

# 5. Start reverse proxy
cd infra/reverse-proxy
docker compose up -d
```

**Note:** All applications must be containerized using Docker Compose. The deployment script validates that apps follow security best practices.

---

## Directory Structure (On Server)

| Path | Purpose |
|------|---------|
| `/opt/hosting-blueprint` | Repository clone (scripts, configs, templates) - *recommended convention* |
| `/srv/apps/dev` | Development environment apps |
| `/srv/apps/staging` | Staging environment apps |
| `/srv/apps/production` | Production environment apps |

CI/CD workflows deploy to `/srv/apps/`, while infrastructure configs live in the repository clone location.

> **Note:** You can clone this repository to any location you prefer. The `/opt/hosting-blueprint` path is a recommended convention used in the documentation and CI/CD examples. If you choose a different path, update the paths in `.github/workflows/deploy.yml` and any cron jobs accordingly.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cloudflare (Free Tier)                       │
│  • SSL/TLS termination   • DDoS protection   • CDN & WAF       │
└────────────────────────────┬────────────────────────────────────┘
                             │ Encrypted Tunnel (outbound only)
                             ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Ubuntu VM (Hardened)                         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              cloudflared (Tunnel Daemon)                 │   │
│  └────────────────────────┬────────────────────────────────┘   │
│                           │ HTTP → localhost:80                 │
│                           ↓                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Caddy (Reverse Proxy - HTTP/80)            │   │
│  │     Routes by subdomain • Security headers • Logging    │   │
│  └────┬──────────────────┬──────────────────┬──────────────┘   │
│       │                  │                  │                   │
│       ↓                  ↓                  ↓                   │
│  ┌─────────┐       ┌──────────┐      ┌────────────┐            │
│  │   DEV   │       │ STAGING  │      │ PRODUCTION │            │
│  │  apps   │       │   apps   │      │    apps    │            │
│  │         │       │          │      │            │            │
│  │ dev-*   │       │ staging- │      │  app.*    │            │
│  │ .domain │       │ *.domain │      │  .domain  │            │
│  └─────────┘       └──────────┘      └────────────┘            │
│       │                  │                  │                   │
│  [dev-backend]    [staging-backend]   [prod-backend]           │
│   (accessible)        (internal)        (internal)             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## File-Based Secrets (No Docker Swarm Needed)

Secrets are stored as files with `chmod 600` and mounted read-only into containers:

```yaml
# In your compose.yml
services:
  app:
    environment:
      - DATABASE_PASSWORD_FILE=/run/secrets/db_password
    volumes:
      - ../../secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
```

**Why file-based?**
- Not visible in `docker inspect` (unlike env vars)
- Same security pattern as Docker Swarm, without Swarm complexity
- Can't accidentally commit to git (gitignored)

```bash
# Create a secret
./scripts/secrets/create-secret.sh staging db_password

# List all secrets
./scripts/secrets/list-secrets.sh

# Rotate a secret
./scripts/secrets/rotate-secret.sh staging db_password
```

---

## Security Hardening (What's Included)

### Network Security
- **Zero open ports** - All traffic via Cloudflare Tunnel
- **Cloudflare Access** - Login screen protects admin panels (see [docs/14-cloudflare-zero-trust.md](docs/14-cloudflare-zero-trust.md))
- **UFW firewall** - Default deny incoming
- **fail2ban** - Auto-bans after 3 failed SSH attempts

### Kernel Hardening
- SYN flood protection (`tcp_syncookies`)
- Full ASLR (`randomize_va_space = 2`)
- Restricted ptrace (`yama.ptrace_scope = 2`)
- Restricted kernel logs (`dmesg_restrict = 1`)

### SSH Hardening
- Key-only authentication (no passwords)
- Root login disabled
- Strong ciphers only (chacha20-poly1305, aes256-gcm)
- Rate limiting

### Docker Hardening
- `no-new-privileges` by default
- Drop all capabilities, add back only what's needed
- Resource limits on all containers
- Internal networks for databases

### Automatic Maintenance
- Security updates auto-installed (with auto-reboot at 2:30 AM)
- Docker cleanup weekly
- Log rotation and retention

---

## Directory Structure

```
.
├── setup.sh                    # Interactive setup entry point
├── README.md
├── SETUP.md                    # Detailed setup guide
├── RUNBOOK.md                  # Operations reference
│
├── scripts/
│   ├── setup-vm.sh             # VM hardening + Docker
│   ├── create-networks.sh      # Docker networks
│   ├── install-cloudflared.sh  # Tunnel setup
│   ├── configure-domain.sh     # Set domain in all configs
│   ├── deploy-app.sh           # Deploy apps with validation
│   ├── verify-tunnel-ssh.sh    # Test SSH via tunnel
│   ├── secrets/                # Secret management
│   │   ├── create-secret.sh
│   │   ├── rotate-secret.sh
│   │   └── list-secrets.sh
│   ├── cloudflare-access/      # Zero Trust helpers
│   │   ├── validate-jwt.js     # JWT validation (Node.js)
│   │   └── validate-jwt.py     # JWT validation (Python)
│   ├── monitoring/             # CLI monitoring
│   │   ├── status.sh           # System dashboard
│   │   ├── logs.sh             # Log viewer
│   │   └── disk-usage.sh       # Disk report
│   ├── maintenance/            # Maintenance tasks
│   │   ├── docker-cleanup.sh
│   │   ├── backup-volumes.sh
│   │   └── check-disk-usage.sh
│   └── security/               # Security hardening
│       └── enable-audit-immutability.sh
│
├── config/                     # System configs (copied to /etc/)
│   ├── sysctl.d/               # Kernel hardening
│   ├── ssh/                    # SSH hardening
│   ├── fail2ban/               # Brute-force protection
│   ├── audit/                  # Security auditing
│   ├── apt/                    # Auto-updates
│   └── cron.d/                 # Scheduled tasks
│
├── secrets/                    # Secret files (gitignored)
│   ├── dev/
│   ├── staging/
│   └── production/
│
├── infra/
│   ├── reverse-proxy/          # Caddy
│   │   ├── compose.yml
│   │   └── Caddyfile
│   └── cloudflared/            # Tunnel config
│
├── apps/
│   ├── _template/              # Copy for new apps
│   └── examples/
│
├── .github/
│   └── workflows/
│       └── deploy.yml          # GitOps CI/CD
│
└── docs/
    ├── 01-cloudflare-setup.md
    ├── 02-security-hardening.md
    └── ...
```

---

## GitOps Workflow

1. **Fork this repo**
2. **Clone and configure** - Run `setup.sh` on your VM
3. **Create feature branch** - `git checkout -b feature/my-feature`
4. **Push** - Auto-deploys to DEV for testing
5. **Create PR to main** - Review, merge → Auto-deploys to STAGING
6. **Create release tag** - `v1.0.0` → Manual deploy to PRODUCTION

### GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `SSH_PRIVATE_KEY` | Ed25519 key for appmgr user |
| `SSH_HOST` | e.g., `ssh.yourdomain.com` |
| `SSH_USER` | e.g., `appmgr` |
| `CF_SERVICE_TOKEN_ID` | Cloudflare Access service token |
| `CF_SERVICE_TOKEN_SECRET` | Cloudflare Access service token secret |

### GitHub Environments

Create these in Settings > Environments:
- `dev` - No protection rules
- `staging` - Optional: require CI pass
- `production` - Require manual approval

---

## Useful Commands

```bash
# System status dashboard
./scripts/monitoring/status.sh

# View logs
./scripts/monitoring/logs.sh              # System logs
./scripts/monitoring/logs.sh docker       # All container logs
./scripts/monitoring/logs.sh security     # Security events

# Disk usage report
./scripts/monitoring/disk-usage.sh

# Secrets management
./scripts/secrets/list-secrets.sh
./scripts/secrets/create-secret.sh dev api_key
./scripts/secrets/rotate-secret.sh staging db_password

# Docker cleanup
./scripts/maintenance/docker-cleanup.sh

# Backup volumes
./scripts/maintenance/backup-volumes.sh
```

---

## Deploy Your First App

```bash
# Copy template
cp -r apps/_template apps/myapp
cd apps/myapp

# Edit configuration
nano .env           # Set ENVIRONMENT, APP_NAME, etc.
nano compose.yml    # Customize as needed

# Create secrets
./scripts/secrets/create-secret.sh dev db_password

# Deploy
docker compose up -d

# Check logs
docker compose logs -f
```

---

## Documentation

- **[SETUP.md](SETUP.md)** - Detailed setup walkthrough
- **[RUNBOOK.md](RUNBOOK.md)** - Daily operations & troubleshooting
- **[secrets/README.md](secrets/README.md)** - Secrets management guide
- **[docs/01-cloudflare-setup.md](docs/01-cloudflare-setup.md)** - Tunnel configuration
- **[docs/02-security-hardening.md](docs/02-security-hardening.md)** - Security deep-dive
- **[docs/14-cloudflare-zero-trust.md](docs/14-cloudflare-zero-trust.md)** - Protect admin panels with login

---

## Requirements

- **Ubuntu** 22.04 or 24.04 LTS
- **RAM** 4GB minimum (2GB will work, 8GB recommended)
- **Disk** 40GB minimum
- **Cloudflare account** (free tier)
- **Domain** with nameservers pointed to Cloudflare

---

## Tested On

- Hetzner Cloud (CX22, CX32)
- DigitalOcean (Basic Droplets)
- Oracle Cloud (Always Free tier)
- Vultr
- Linode

---

## Production Hardening Checklist

After initial setup is working, apply these additional hardening steps for production:

- [ ] **Enable audit immutability** - Prevent attackers from disabling audit logging:
  ```bash
  sudo ./scripts/security/enable-audit-immutability.sh
  ```
  *(Requires reboot; audit rules cannot be changed until next reboot)*

- [ ] **Configure fail2ban email notifications** - Get alerted on intrusion attempts:
  ```bash
  sudo nano /etc/fail2ban/jail.local
  # Uncomment and configure: destemail, sender, mta, action_mwl
  ```

- [ ] **Close direct SSH port** - Only after verifying tunnel SSH works:
  ```bash
  sudo ufw delete allow OpenSSH
  sudo ufw delete allow 22/tcp
  ```

- [ ] **Enable Cloudflare Access** - Add login page before admin panels:
  - See [docs/14-cloudflare-zero-trust.md](docs/14-cloudflare-zero-trust.md)

- [ ] **Review resource limits** - Adjust container CPU/memory limits based on your workload

- [ ] **Set up backups** - Enable volume backup cron job:
  ```bash
  # Uncomment backup line in /etc/cron.d/vm-maintenance
  ```

- [ ] **Configure monitoring alerts** - Set up Netdata or external monitoring

---

## License

MIT

---

## Questions?

Check [docs/05-troubleshooting.md](docs/05-troubleshooting.md) or open an issue.
