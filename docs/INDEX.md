# Documentation Index

Complete guide to setting up and managing your hardened multi-environment VM.

## 📖 Documentation Overview

All documentation is organized by topic to help you find what you need quickly.

---

## 🚀 Getting Started (Start Here!)

Essential guides for first-time setup:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [00-initial-setup.md](00-initial-setup.md) | **START HERE** - Complete setup from fresh VM | 10 min |
| [01-cloudflare-setup.md](01-cloudflare-setup.md) | Configure Cloudflare Tunnel for zero-port architecture | 15 min |
| [quick-start-repository-setup.md](quick-start-repository-setup.md) | Quick command reference for repository initialization | 5 min |

**Recommended Reading Order:** 00 → 01 → quick-start-repository-setup

---

## 🔐 Security & Hardening

Security configuration and best practices:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [02-security-hardening.md](02-security-hardening.md) | Kernel hardening, SSH hardening, fail2ban, auditd | 20 min |
| [09-hardening-checklist.md](09-hardening-checklist.md) | Complete security checklist for production readiness | 10 min |
| [14-cloudflare-zero-trust.md](14-cloudflare-zero-trust.md) | Protect admin panels with Cloudflare Access | 15 min |

**Key Takeaway:** This template provides enterprise-grade security out of the box.

---

## 🏗️ Architecture & Infrastructure

Understanding how everything works:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [04-architecture.md](04-architecture.md) | System architecture and design decisions | 15 min |
| [filesystem-layout.md](filesystem-layout.md) | `/srv` structure and FHS compliance | 10 min |
| [directory-structure.md](directory-structure.md) | Project directory organization | 5 min |
| [infrastructure-template-structure.md](infrastructure-template-structure.md) | How templates are organized | 5 min |
| [repository-structure.md](repository-structure.md) | Repository layout and conventions | 5 min |

**Best Practice:** Read 04-architecture.md first to understand the big picture.

---

## 🌐 Networking & Routing

Configure reverse proxy and DNS:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [03-network-setup.md](03-network-setup.md) | Docker networks and environment isolation | 10 min |
| [caddy-configuration-guide.md](caddy-configuration-guide.md) | Caddy reverse proxy configuration examples | 20 min |

**Pro Tip:** Caddy automatically handles SSL certificates via Cloudflare.

---

## 📦 Application Deployment

Deploy and manage applications:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [12-running-multiple-apps.md](12-running-multiple-apps.md) | Deploy multiple apps with environment isolation | 15 min |
| [08-environment-tiers.md](08-environment-tiers.md) | Dev, staging, production environments | 10 min |

**Recommended Workflow:** Deploy to dev → test → promote to staging → production.

---

## 🔒 Secrets & Configuration

Secure secrets management:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [06-secrets-management.md](06-secrets-management.md) | File-based secrets system (not in git) | 15 min |

**Important:** Secrets are stored in `/var/secrets/` with 600 permissions, never in git.

---

## 🔄 GitOps & CI/CD

Automated deployment workflows:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [07-gitops-workflow.md](07-gitops-workflow.md) | GitHub Actions deployment pipeline | 20 min |

**Workflow:** Feature branch → DEV, main branch → STAGING, git tag → PRODUCTION.

---

## 👥 User Management

Manage system users and permissions:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [10-user-management.md](10-user-management.md) | Two-user system (sysadmin + appmgr) | 10 min |

**Security Model:** `sysadmin` for administration, `appmgr` for CI/CD (no sudo).

---

## 📊 Monitoring & Operations

Monitor and maintain your VM:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [13-monitoring-with-netdata.md](13-monitoring-with-netdata.md) | Real-time system monitoring dashboard | 10 min |
| [11-vm-best-practices.md](11-vm-best-practices.md) | Maintenance, backups, and operational best practices | 15 min |

**Monitoring Stack:** Netdata for system metrics, Portainer for Docker management.

---

## 🛠️ Troubleshooting & Reference

Quick reference and problem solving:

| Guide | Description | Read Time |
|-------|-------------|-----------|
| [05-troubleshooting.md](05-troubleshooting.md) | Common issues and solutions | 10 min |
| [quick-reference.md](quick-reference.md) | Command cheat sheet for daily operations | 5 min |

**Stuck?** Check troubleshooting guide first, then check GitHub issues.

---

## 📚 Reading Paths by Use Case

### Path 1: First-Time Setup (New VM)
1. [00-initial-setup.md](00-initial-setup.md) - Complete setup guide
2. [01-cloudflare-setup.md](01-cloudflare-setup.md) - Configure tunnel
3. [09-hardening-checklist.md](09-hardening-checklist.md) - Verify security
4. [12-running-multiple-apps.md](12-running-multiple-apps.md) - Deploy your first app

**Estimated Time:** 1-2 hours

---

### Path 2: Understanding Architecture
1. [04-architecture.md](04-architecture.md) - System design
2. [filesystem-layout.md](filesystem-layout.md) - Directory structure
3. [03-network-setup.md](03-network-setup.md) - Network isolation
4. [caddy-configuration-guide.md](caddy-configuration-guide.md) - Routing

**Estimated Time:** 1 hour

---

### Path 3: Security Hardening Deep Dive
1. [02-security-hardening.md](02-security-hardening.md) - Hardening measures
2. [09-hardening-checklist.md](09-hardening-checklist.md) - Verification
3. [14-cloudflare-zero-trust.md](14-cloudflare-zero-trust.md) - Zero Trust Access
4. [06-secrets-management.md](06-secrets-management.md) - Secrets handling

**Estimated Time:** 1 hour

---

### Path 4: Production Deployment
1. [08-environment-tiers.md](08-environment-tiers.md) - Environment strategy
2. [07-gitops-workflow.md](07-gitops-workflow.md) - CI/CD setup
3. [06-secrets-management.md](06-secrets-management.md) - Production secrets
4. [11-vm-best-practices.md](11-vm-best-practices.md) - Operations

**Estimated Time:** 1.5 hours

---

### Path 5: Daily Operations
1. [quick-reference.md](quick-reference.md) - Common commands
2. [13-monitoring-with-netdata.md](13-monitoring-with-netdata.md) - Monitoring
3. [05-troubleshooting.md](05-troubleshooting.md) - Problem solving
4. [11-vm-best-practices.md](11-vm-best-practices.md) - Maintenance

**Estimated Time:** 30 min

---

## 🎯 Quick Links by Task

### "I want to deploy my first app"
→ [12-running-multiple-apps.md](12-running-multiple-apps.md)

### "I need to configure routing"
→ [caddy-configuration-guide.md](caddy-configuration-guide.md)

### "I want to set up CI/CD"
→ [07-gitops-workflow.md](07-gitops-workflow.md)

### "I need to manage secrets"
→ [06-secrets-management.md](06-secrets-management.md)

### "I want to understand security"
→ [02-security-hardening.md](02-security-hardening.md)

### "Something's broken"
→ [05-troubleshooting.md](05-troubleshooting.md)

### "I need command examples"
→ [quick-reference.md](quick-reference.md)

---

## 📝 Documentation Standards

All guides follow this structure:

- **Prerequisites** - What you need before starting
- **What You'll Learn** - Learning objectives
- **Step-by-step instructions** - Clear, actionable steps
- **Verification** - How to verify it worked
- **Next Steps** - What to do next

---

## 🤝 Contributing to Docs

Found an error? Want to improve a guide?

1. Create an issue describing the problem
2. Submit a PR with your improvements
3. Follow the documentation standards above

See [CONTRIBUTING.md](../CONTRIBUTING.md) for details.

---

## 📊 Documentation Stats

- **Total Guides:** 21
- **Total Reading Time:** ~4 hours
- **Quick Start Time:** 1-2 hours
- **Coverage:** Setup, Security, Networking, Deployment, Operations, Troubleshooting

---

## 🆘 Need Help?

- **Questions:** Open a GitHub Discussion
- **Bug Report:** File an issue with the `bug` label
- **Feature Request:** File an issue with the `enhancement` label
- **Security Issue:** Email security@yourdomain.com (not public GitHub)

---

<p align="center">
  <sub>Documentation maintained by the community. Last updated: 2026-02</sub>
</p>
