# 🔒 Hardened Multi-Environment VM with Cloudflare Tunnel

> Production-ready VM setup with **zero open ports**, enterprise-grade security, and GitOps workflow. Deploy in 15 minutes.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Ubuntu 22.04/24.04](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-orange.svg)](https://ubuntu.com/)
[![Cloudflare Tunnel](https://img.shields.io/badge/Cloudflare-Tunnel-orange.svg)](https://www.cloudflare.com/)

---

## ✨ Features

- 🚫 **Zero Open Ports** - All access via Cloudflare Tunnel (SSH, HTTP/HTTPS)
- 🔐 **Enterprise Security** - Kernel hardening, SSH hardening, fail2ban, auditd
- 🐳 **Docker-First** - Secure defaults, resource limits, file-based secrets
- 🌐 **Free SSL** - Automatic wildcard certificates (`*.yourdomain.com`)
- 🔄 **GitOps Ready** - Feature branches → DEV, main → STAGING, tags → PROD
- 📊 **Three Environments** - Isolated dev, staging, production with separate networks
- 🤖 **AI Agent Ready** - Secure hosting for LLM agents with resource controls
- ⚡ **Fast Setup** - One command from fresh VM to production-ready

---

## 🚀 Quick Start

### Prerequisites (5 minutes)

1. **VPS/VM** - Ubuntu 22.04 or 24.04 (2GB+ RAM, 20GB+ disk)
2. **Domain** - Registered domain name
3. **Cloudflare** - Free account at [cloudflare.com](https://cloudflare.com)
4. **SSH Key** - For secure access

**Detailed guide:** [docs/00-initial-setup.md](docs/00-initial-setup.md)

### Installation (15 minutes)

SSH to your VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/main/bootstrap.sh | sudo bash
```

That's it! The script will:

- ✅ Harden your VM (SSH, kernel, firewall, fail2ban)
- ✅ Install Docker with security defaults
- ✅ Create two users (sysadmin + appmgr)
- ✅ Set up Cloudflare Tunnel
- ✅ Configure reverse proxy (Caddy)
- ✅ Verify everything works

**Interactive Setup:** You'll be prompted for:

- Domain name (e.g., `yourdomain.com`)
- SSH public keys (paste from your local machine)
- Sysadmin sudo mode (password required recommended vs passwordless)
- Timezone (defaults to UTC)
- Cloudflare Tunnel setup (yes/no)

---

## 📖 Documentation

- **[Initial Setup Guide](docs/00-initial-setup.md)** - Start here!
- **[Detailed Setup](SETUP.md)** - Step-by-step walkthrough
- **[Daily Operations](RUNBOOK.md)** - Common tasks
- **[Architecture](docs/04-architecture.md)** - How it works
- **[GitOps Workflow](docs/07-gitops-workflow.md)** - CI/CD with GitHub Actions
- **[Secrets Management](docs/06-secrets-management.md)** - File-based secrets
- **[Troubleshooting](docs/05-troubleshooting.md)** - Common issues

---

## 🏗️ What's Included

### Security

- SSH hardening (key-only, strong ciphers)
- Kernel hardening (ASLR, ptrace restrictions, SYN flood protection)
- UFW firewall with default deny
- fail2ban (automatic IP banning)
- auditd (security event logging)
- Automatic security updates

### Infrastructure

- Cloudflare Tunnel (zero open ports)
- Caddy reverse proxy (automatic HTTPS)
- Docker + Docker Compose v2
- Three isolated environments (dev/staging/prod)
- File-based secrets system

### Monitoring

- System status dashboard
- Log aggregation
- Disk usage monitoring
- Container health checks

---

## 🔧 Usage

### Deploy Third-Party Apps (Wizard)

```bash
./scripts/post-setup-wizard.sh
```

### Deploy From Template

```bash
sudo mkdir -p /srv/apps/staging
sudo cp -r /opt/hosting-blueprint/apps/_template /srv/apps/staging/myapp
cd /srv/apps/staging/myapp
sudo docker compose up -d
```

### Use Included Examples

Examples live under `apps/examples/` (copy into `/srv/apps/<env>/`):

- `apps/examples/hello-world`
- `apps/examples/simple-api`
- `apps/examples/python-fastapi`
- `apps/examples/postgres`

### Deploy Custom Apps

```bash
./scripts/setup-custom-app.sh \
  --repo https://github.com/yourorg/your-app \
  --env production \
  --subdomain api
```

### SSH via Tunnel

```bash
# After setup completes
ssh yourdomain      # Connects as sysadmin
ssh yourdomain-appmgr "hosting status dev"  # appmgr is CI-only (restricted)
```

---

## 🎯 Use Cases

- 🤖 **AI Agent Hosting** - LLM agents, autonomous workflows
- 🌐 **Web Applications** - APIs, websites, dashboards
- 🔄 **CI/CD Pipelines** - GitHub Actions deployment target
- 📊 **Data Services** - Databases, message queues, cache
- 📈 **Monitoring Stacks** - Grafana, Prometheus, Netdata
- 🛠️ **Dev/Staging Environments** - Isolated testing environments

---

## 🌟 Why This Template?

### vs. Manual Setup

- ❌ **Manual:** 4+ hours of configuration
- ✅ **This:** 15 minutes automated

### vs. Other Hardening Scripts

- ❌ **Others:** SSH port 22 still exposed
- ✅ **This:** Zero open ports via tunnel

### vs. Docker-Only

- ❌ **Docker-only:** No VM hardening
- ✅ **This:** Full stack security

### vs. Cloud Provider Defaults

- ❌ **Defaults:** Wide open, insecure
- ✅ **This:** Locked down, audited

---

## 📊 Verification

After setup, you'll see:

```
╔══════════════════════════════════════════════════════════╗
║ Setup Verification Results                               ║
╠══════════════════════════════════════════════════════════╣
║ System Security:                         [6/6] ✓ PASS   ║
║ User Configuration:                      [5/5] ✓ PASS   ║
║ Docker Configuration:                    [5/5] ✓ PASS   ║
║ Infrastructure Services:                 [4/4] ✓ PASS   ║
║ Network & DNS:                           [5/5] ✓ PASS   ║
║ SSH Connectivity:                        [5/5] ✓ PASS   ║
╠══════════════════════════════════════════════════════════╣
║ Overall Status:                          ✓ READY         ║
║                                                          ║
║ Your VM is hardened and ready for production!           ║
╚══════════════════════════════════════════════════════════╝
```

---

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md)

---

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

Built with security best practices from:

- NIST Cybersecurity Framework
- CIS Benchmarks (Ubuntu)
- OWASP Top 10
- Docker Security Best Practices

---

## ⭐ Star This Repo

If this helped you, please star the repo and share with others!

---

## 🗺️ Roadmap

- [x] Zero-port security via Cloudflare Tunnel
- [x] Multi-environment isolation (dev/staging/prod)
- [x] File-based secrets management
- [x] GitOps workflow with GitHub Actions
- [x] One-liner installation
- [ ] Secrets integration with HashiCorp Vault
- [ ] Kubernetes migration path
- [ ] Multi-region deployment guide
- [ ] Advanced monitoring with Prometheus/Grafana

---

<p align="center">
  <sub>Built with ❤️ for secure, production-ready infrastructure</sub>
</p>
