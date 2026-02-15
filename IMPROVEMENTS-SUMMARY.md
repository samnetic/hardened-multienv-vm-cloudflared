# Improvements Summary (Security-First Blueprint)

This repo is a security-first VPS blueprint for multi-environment Docker Compose apps behind Cloudflare Tunnel.

## What’s Hardened

### Zero-Port / Tunnel-Only Architecture

- Caddy binds `127.0.0.1:80` only (origin not reachable from the internet).
- Optional `scripts/finalize-tunnel.sh` migrates DNS to Tunnel CNAMEs and closes port 22 + HTTP(S) on UFW (true “zero ports”).
- Defense-in-depth in `infra/reverse-proxy/Caddyfile`: a `tunnel_only` gate rejects requests not coming from loopback or the Docker NAT gateway on `hosting-caddy-origin` (`10.250.0.1`), blocking origin IP bypass and container-to-container bypasses.

### Linux Host Hardening

- SSH hardening: `config/ssh/sshd_config.d/hardening.conf`
- Firewall baseline: `scripts/setup-vm.sh` enables UFW (deny inbound by default; temporary SSH allow for bootstrap).
- fail2ban: SSH brute-force protection
- auditd: baseline audit rules + change tracking for sensitive files
- kernel/sysctl hardening: `config/sysctl.d/99-hardening.conf`
- unattended security updates + scheduled reboots: `config/apt/apt.conf.d/50unattended-upgrades`
- journald retention configuration (30 days / 500MB default)
- log rotation for blueprint logs: `config/logrotate.d/hosting-blueprint`
- scheduled maintenance: `config/cron.d/vm-maintenance` (Docker pruning, journald vacuum, disk checks)

### Docker Security Defaults

- Docker daemon defaults written by `scripts/setup-vm.sh` (safe logging, live-restore, loopback publish default, etc.).
- Docker daemon metrics enabled at `0.0.0.0:9323` (host) so a least-privilege proxy can expose metrics internally without `docker.sock`. Keep this port firewalled (UFW default deny).
- Humans are not added to the `docker` group (docker group is root-equivalent); operate with `sudo docker ...`.
- Port exposure guardrail: `scripts/security/check-docker-exposed-ports.sh` (daily cron + post-deploy check).

### GitOps CI Trust Model (Major Upgrade)

- CI connects as `appmgr`, but cannot get an interactive shell:
  - `sshd Match User appmgr` + `ForceCommand /usr/local/sbin/hosting-ci-ssh`
- `appmgr` has a strict sudo allowlist to one root-owned tool only:
  - `/usr/local/sbin/hosting-deploy` (`sync`, `deploy`, `status`)
- Deploys run with compose policy checks (deny privileged/host namespaces/devices/docker.sock/bad binds, `build:`, and `ports:` by default).
- GitHub Actions deploy uses:
  - Cloudflare Access Service Token via `cloudflared access ssh` ProxyCommand
  - `git archive | gzip | ssh "hosting sync <env>"`
  - `ssh "hosting deploy <env> <ref>"`

### Secrets

- File-based secrets under `/var/secrets/...` (recommended).
- Optional SOPS+age support: commit `.env.<env>.enc`, decrypt on the VM at deploy time (see `scripts/security/setup-sops-age.sh`).

### Optional Security Tooling

Install via: `sudo ./scripts/security/setup-security-tools.sh`

- AIDE (daily), rkhunter (weekly), Lynis (weekly), debsums (weekly), acct
- Schedules: `config/cron.d/security-scans`
- Logs: `/var/log/hosting-blueprint/security/` (rotated by `config/logrotate.d/security-tools`)
- Optional alerting via `/etc/hosting-blueprint/alerting.env` (webhook/email)
- Optional `/tmp` tmpfs hardening: `scripts/security/enable-tmpfs-tmp.sh`

## UX / Setup Flow

- `bootstrap.sh`: clone + run (one-liner friendly)
- `setup.sh`: interactive end-to-end setup
- `scripts/post-setup-wizard.sh`: fast path to initialize `/srv/infrastructure` and deploy a first app
- `scripts/verify-setup.sh`: sanity checks + safe guidance
- `scripts/dev/validate-repo.sh` + `.github/workflows/validate.yml`: static checks (bash syntax, YAML parse, deploy tool compile) to catch regressions early

## Recommended Operational Pattern

- Protect every admin hostname with Cloudflare Access SSO.
- Use Access Service Tokens for CI and machine-to-machine endpoints.
- Keep monitoring on a separate VPS if it requires docker socket mounts, host PID namespace, or extra capabilities.

## Monitoring (Two-VPS Pattern)

- App VPS exporters (no published ports): `infra/monitoring-agent/`
  - `node-exporter` (system metrics)
  - `dockerd-metrics-proxy` (Docker daemon metrics without `docker.sock`)
  - Optional `compose.cadvisor.yml` for per-container metrics (higher privilege; protect with Access Service Auth)
- Separate monitoring VPS stack: `infra/monitoring-server/`
  - Prometheus + Grafana + Alertmanager
  - Scrape through Cloudflare Access Service Tokens (machine auth)
  - Safety: `scripts/monitoring/init-monitoring-server.sh` prevents missing-secret bind-mount footguns and bootstraps required secrets

## Quick Smoke Test On a Fresh VPS

1. Install and harden:
   ```bash
   sudo bash bootstrap.sh
   ```

2. Verify:
   ```bash
   ./scripts/verify-setup.sh
   ```

3. Confirm “tunnel-only” is intact:
   ```bash
   sudo /opt/scripts/check-docker-exposed-ports.sh
   sudo ss -lntup | rg ':80|:443|:22' || true
   ```
