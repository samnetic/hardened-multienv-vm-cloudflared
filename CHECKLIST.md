# Pre-Release Checklist

Use this checklist before publishing your VM template to GitHub or deploying to production.

## 📋 Repository Setup

- [ ] **Update GitHub URLs** in bootstrap.sh and README.md with your repository URL
- [ ] **Set repository visibility** (public or private) on GitHub
- [ ] **Add repository description** and tags on GitHub
- [ ] **Enable GitHub Discussions** (recommended for community support)
- [ ] **Enable GitHub Issues** for bug tracking
- [ ] **Add README badges** with correct links
- [ ] **Create initial release** (v1.0.0) with release notes

## 🔐 Security Review

- [ ] **No hardcoded secrets** in any files (check with `git grep -i password`)
- [ ] **No API keys** committed (check with `git grep -i api_key`)
- [ ] **Review .gitignore** - ensures .env files are excluded
- [ ] **Review file permissions** - scripts are executable (755), docs are readable (644)
- [ ] **Audit user accounts** - default users disabled, only sysadmin/appmgr active
- [ ] **Verify SSH config** - key-only authentication, no password auth

## 📚 Documentation

- [ ] **README.md is complete** with quick start and prerequisites
- [ ] **SETUP.md has step-by-step instructions**
- [ ] **RUNBOOK.md covers daily operations**
- [ ] **All docs in docs/ are up-to-date** (run `ls docs/` to verify)
- [ ] **docs/INDEX.md organizes all guides**
- [ ] **CONTRIBUTING.md explains how to contribute**
- [ ] **CODE_OF_CONDUCT.md is present**
- [ ] **LICENSE file is correct** (MIT license included)

## 🧪 Testing

### Test on Fresh VM

- [ ] **Create fresh Ubuntu 22.04/24.04 VM** (minimum 2GB RAM, 20GB disk)
- [ ] **Run bootstrap.sh** from GitHub (test the one-liner)
- [ ] **Verify all setup steps complete** without errors
- [ ] **Run verify-setup.sh** - all checks should pass
- [ ] **Test post-setup-wizard.sh** - verify guided deployment works
- [ ] **Deploy example app** (hello-world, simple-api, or python-fastapi)
- [ ] **Verify app is accessible** via Cloudflare tunnel
- [ ] **Test SSH access** via tunnel (no direct port 22 exposure)
- [ ] **Check Docker networking** - dev/staging/prod networks isolated
- [ ] **Test Caddy reverse proxy** - routes correctly
- [ ] **Verify Cloudflare DNS** - no A records exposing IP

### Security Testing

- [ ] **Run port scan** - verify zero open ports: `nmap -p- YOUR_VM_IP`
- [ ] **Test SSH hardening** - password auth disabled, only key access
- [ ] **Check firewall rules** - `sudo ufw status` shows default deny
- [ ] **Verify fail2ban** - `sudo fail2ban-client status` shows active jails
- [ ] **Test Docker security** - containers run with no-new-privileges
- [ ] **Check auditd logs** - security events logged: `sudo ausearch -m avc`
- [ ] **Verify kernel hardening** - `sysctl -a | grep kernel` shows hardened values

## 🎨 User Experience

- [ ] **One-liner install works** from fresh VM
- [ ] **Pre-flight checks are helpful** (OS, RAM, disk, network)
- [ ] **Interactive prompts are clear** with validation
- [ ] **Error messages are helpful** with actionable guidance
- [ ] **Post-setup wizard is intuitive** and guides first deployment
- [ ] **Documentation is easy to navigate** (docs/INDEX.md helps)
- [ ] **Examples work out-of-box** (hello-world, simple-api, python-fastapi)

## 📦 Examples & Templates

- [ ] **apps/_template/ is complete** with README, compose.yml, .env.example
- [ ] **apps/examples/hello-world/ works** - static nginx site deploys
- [ ] **apps/examples/simple-api/ works** - Node.js API deploys
- [ ] **apps/examples/python-fastapi/ works** - Python FastAPI deploys
- [ ] **All examples have README** with deployment instructions
- [ ] **All examples have .env.example** files
- [ ] **All examples use security best practices** (no-new-privileges, resource limits)

## 🔧 Scripts

- [ ] **All scripts are executable** - `find scripts -name "*.sh" -exec chmod +x {} \;`
- [ ] **All scripts have proper shebangs** (#!/usr/bin/env bash)
- [ ] **All scripts have help text** when run with --help or -h
- [ ] **All scripts handle errors gracefully** (set -euo pipefail)
- [ ] **All scripts provide clear output** (color-coded, progress indicators)

### Key Scripts to Test

- [ ] **bootstrap.sh** - clones repo and launches setup
- [ ] **setup.sh** - main setup script runs without errors
- [ ] **scripts/verify-setup.sh** - all verification checks pass
- [ ] **scripts/post-setup-wizard.sh** - guides first app deployment
- [ ] **scripts/init-infrastructure.sh** - creates /srv structure
- [ ] **scripts/deploy-app.sh** - deploys apps successfully
- [ ] **scripts/update-caddy.sh** - reloads Caddy without downtime
- [ ] **scripts/secrets/create-secret.sh** - creates secrets with 600 permissions
- [ ] **scripts/monitoring/status.sh** - shows system status
- [ ] **scripts/maintenance/backup-volumes.sh** - backs up Docker volumes

## 🌐 Cloudflare Integration

- [ ] **Tunnel setup works** - scripts/install-cloudflared.sh installs tunnel
- [ ] **DNS configuration guide is clear** (docs/01-cloudflare-setup.md)
- [ ] **Zero Trust docs are accurate** (docs/14-cloudflare-zero-trust.md)
- [ ] **Tunnel reconnects after reboot** - systemd service enabled
- [ ] **DNS CNAME records documented** with examples

## 🎯 Production Readiness

- [ ] **Backup system works** - scripts/maintenance/backup-volumes.sh runs
- [ ] **Cron jobs configured** - automatic updates and backups scheduled
- [ ] **Monitoring is set up** - Netdata or Portainer available
- [ ] **Disk cleanup works** - scripts/maintenance/docker-cleanup.sh runs
- [ ] **Log rotation configured** - /etc/logrotate.d/ has configs
- [ ] **Health checks enabled** - all containers have healthcheck
- [ ] **Resource limits set** - all containers have CPU/memory limits

## 🔄 GitOps & CI/CD

- [ ] **GitHub Actions workflow exists** (.github/workflows/)
- [ ] **Workflow tests pass** for dev/staging/prod branches
- [ ] **Secrets documented** - docs/07-gitops-workflow.md explains setup
- [ ] **Deployment process tested** - push triggers deployment
- [ ] **Rollback process tested** - can revert to previous version

## 📊 Community Files

- [ ] **CONTRIBUTING.md exists** and explains PR process
- [ ] **CODE_OF_CONDUCT.md exists**
- [ ] **Issue templates exist** (.github/ISSUE_TEMPLATE/)
- [ ] **PR template exists** (.github/PULL_REQUEST_TEMPLATE.md)
- [ ] **GitHub Discussions enabled** (optional but recommended)

## 🚀 Release Preparation

- [ ] **Version number updated** in README and release notes
- [ ] **CHANGELOG.md created** with all changes since last release
- [ ] **Release notes written** with highlights and breaking changes
- [ ] **Migration guide created** (if upgrading from previous version)
- [ ] **Known issues documented** (if any)

## 📢 Launch

- [ ] **Create GitHub release** with tag (e.g., v1.0.0)
- [ ] **Publish to relevant communities** (Reddit, HackerNews, etc.)
- [ ] **Tweet announcement** (if applicable)
- [ ] **Submit to awesome-lists** (awesome-selfhosted, awesome-sysadmin)
- [ ] **Monitor GitHub issues** for first-time user feedback

## ✅ Final Verification

Run these commands on a fresh VM to verify everything works:

```bash
# 1. One-liner install (replace URL with your repo)
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/bootstrap.sh | sudo bash

# 2. Verify setup
cd /opt/hosting-blueprint
./scripts/verify-setup.sh

# 3. Run post-setup wizard
./scripts/post-setup-wizard.sh

# 4. Deploy example app
cp -r apps/examples/hello-world /srv/apps/production/test-app
cd /srv/apps/production/test-app
docker compose up -d

# 5. Verify zero open ports
nmap -p- $(hostname -I | awk '{print $1}')
# Should show: "All 65535 scanned ports are in ignored states"

# 6. Check security
./scripts/verify-setup.sh

# Expected: All checks pass ✓
```

## 🎉 You're Ready!

Once all items are checked, your VM template is ready for:
- ✅ Public release on GitHub
- ✅ Production deployment
- ✅ Community contributions
- ✅ Enterprise use

---

<p align="center">
  <sub>Last updated: 2026-02</sub>
</p>
