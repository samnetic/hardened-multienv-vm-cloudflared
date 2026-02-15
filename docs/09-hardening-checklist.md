# Security Hardening Checklist

Quick reference for verifying your server is properly hardened.

## Pre-Flight Checks

Run these after setup to verify hardening is applied:

```bash
# All-in-one status check
./scripts/monitoring/status.sh
```

---

## SSH Hardening

### Verify Settings

```bash
# Check SSH configuration
sudo sshd -T | grep -E "permitrootlogin|passwordauthentication|pubkeyauthentication"
```

**Expected output:**
```
permitrootlogin no
passwordauthentication no
pubkeyauthentication yes
```

### Checklist

- [ ] Root login disabled
- [ ] Password authentication disabled
- [ ] Only key-based authentication
- [ ] Strong ciphers configured
- [ ] MaxAuthTries set to 3
- [ ] AllowUsers restricts to sysadmin, appmgr

---

## Firewall (UFW)

### Verify Status

```bash
sudo ufw status verbose
```

**Expected:** Default deny incoming, allow outgoing

### Checklist

- [ ] UFW enabled
- [ ] Default deny incoming
- [ ] Default allow outgoing
- [ ] Only necessary ports allowed (or none with tunnel)

---

## Kernel Hardening

### Verify Settings

```bash
# Check critical sysctl values
sysctl kernel.randomize_va_space    # Should be 2
sysctl kernel.yama.ptrace_scope     # Should be 2
sysctl kernel.dmesg_restrict        # Should be 1
sysctl net.ipv4.tcp_syncookies      # Should be 1
```

### Checklist

- [ ] ASLR enabled (randomize_va_space = 2)
- [ ] ptrace restricted (yama.ptrace_scope = 2)
- [ ] Kernel logs restricted (dmesg_restrict = 1)
- [ ] SYN cookies enabled (tcp_syncookies = 1)
- [ ] ICMP redirects disabled
- [ ] Source routing disabled

---

## fail2ban

### Verify Status

```bash
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

### Checklist

- [ ] fail2ban running
- [ ] SSH jail enabled
- [ ] Reasonable ban times (86400s = 24h for SSH)
- [ ] Progressive ban times enabled

---

## Audit Logging

### Verify Status

```bash
sudo systemctl status auditd
sudo auditctl -l | head -10
```

### Checklist

- [ ] auditd running
- [ ] Critical files monitored (/etc/passwd, /etc/shadow, etc.)
- [ ] Privileged commands logged
- [ ] Rules immutable (-e 2)

---

## Automatic Updates

### Verify Status

```bash
sudo systemctl status unattended-upgrades
cat /etc/apt/apt.conf.d/50unattended-upgrades | grep -E "Automatic-Reboot|Allowed-Origins"
sudo systemctl list-timers --all | grep hosting-cloudflared-upgrade || true
```

### Checklist

- [ ] unattended-upgrades installed and running
- [ ] Security updates enabled
- [ ] cloudflared auto-upgrade timer enabled (`hosting-cloudflared-upgrade.timer`)
- [ ] Automatic reboot enabled (for kernel updates)
- [ ] Reboot time set (default 02:30)

---

## Docker Hardening

### Verify daemon.json

```bash
cat /etc/docker/daemon.json
```

**Expected:**
```json
{
  "log-driver": "local",
  "log-opts": {"max-size": "20m", "max-file": "5"},
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "ip": "127.0.0.1"
}
```

Notes:
- `ip: 127.0.0.1` makes Docker’s default published-port bind loopback-only (helps preserve the tunnel-only model).
- You may also see `metrics-addr` (Docker daemon metrics; keep firewalled) and `default-address-pools` (normal in this blueprint).

### Verify Container Defaults

```bash
# Check a running container
sudo docker inspect mycontainer | jq '.[0].HostConfig.SecurityOpt'
# Should include "no-new-privileges"
```

### Checklist

- [ ] Log rotation configured
- [ ] live-restore enabled
- [ ] no-new-privileges by default
- [ ] Inter-container communication disabled (icc: false)
- [ ] Containers have resource limits
- [ ] Containers drop capabilities

---

## Network Isolation

### Verify Networks

```bash
sudo docker network ls | grep -E "dev-|staging-|prod-|hosting-caddy-origin"
sudo docker network inspect staging-backend | jq '.[0].Internal'
sudo docker network inspect prod-backend | jq '.[0].Internal'
sudo docker network inspect hosting-caddy-origin --format 'internal={{.Internal}} gateway={{(index .IPAM.Config 0).Gateway}}'
```

### Checklist

- [ ] dev-backend is NOT internal (bridge, for local dev access)
- [ ] staging-backend IS internal
- [ ] prod-backend IS internal
- [ ] hosting-caddy-origin is internal and gateway is `10.250.0.1` (Caddy tunnel-only enforcement)
- [ ] Apps and databases on separate networks

---

## User Management

### Verify Users

```bash
# Check sysadmin has sudo
groups sysadmin

# Check appmgr is restricted (no docker group, no sudo shell)
groups appmgr

# Check SSH restriction is installed for appmgr
sudo grep -n "ForceCommand /usr/local/sbin/hosting-ci-ssh" /etc/ssh/sshd_config.d/99-appmgr-ci.conf

# Check password lock status (SSH password auth is disabled regardless)
sudo passwd -S sysadmin
sudo passwd -S appmgr

# Expected:
# - sysadmin: P (password set) if SYSADMIN_SUDO_MODE=password, or NP/L if SYSADMIN_SUDO_MODE=nopasswd
# - appmgr:   L (locked)
```

### Checklist

- [ ] sysadmin user exists with sudo
- [ ] appmgr user exists WITHOUT sudo
- [ ] sysadmin is NOT in docker group (prevents docker-socket root escalation without sudo password)
- [ ] appmgr is NOT in docker group
- [ ] appmgr is restricted via sshd `ForceCommand` to `hosting ...` only
- [ ] No password authentication (keys only)
- [ ] Root direct login disabled

---

## GitOps / CI Security

### Checklist

- [ ] Cloudflare Access protects `ssh.<domain>` (SSO for humans, Service Tokens for CI)
- [ ] GitHub Actions pins SSH host key (`SSH_KNOWN_HOSTS`) and does not disable host key checking
- [ ] CI uses a dedicated deploy key (not a personal workstation key)

---

## Secrets Management

### Verify Permissions

```bash
sudo ls -la /var/secrets/*/
# All .txt files should be root:hosting-secrets 640
```

### Checklist

- [ ] Secret files have 640 permissions (root:hosting-secrets)
- [ ] Secrets stored in /var/secrets (not in git)
- [ ] No secrets in environment variables (use _FILE pattern)
- [ ] Different secrets per environment

---

## Optional Security Tools

If you want file integrity monitoring and periodic audits:

```bash
sudo ./scripts/security/setup-security-tools.sh
```

### Checklist

- [ ] AIDE baseline initialized
- [ ] Weekly Lynis + rkhunter scans scheduled (`/etc/cron.d/security-scans`)
- [ ] Logs rotated (`/etc/logrotate.d/security-tools`)
- [ ] Alerting configured (optional) via `/etc/hosting-blueprint/alerting.env`

---

## Cloudflare Tunnel

### Verify Status

```bash
sudo systemctl status cloudflared
```

### Verify No Open Ports

```bash
# From external machine or using online port scanner
nmap -p- your-server-ip
# Should show all ports filtered/closed
```

### Checklist

- [ ] cloudflared running as service
- [ ] SSH via tunnel only (port 22 closed externally)
- [ ] HTTP/HTTPS via tunnel only
- [ ] No direct port exposure

---

## Quick Verification Script

Run this to check everything at once:

```bash
#!/bin/bash
echo "=== SSH ==="
sudo sshd -T 2>/dev/null | grep -E "permitrootlogin|passwordauthentication"

echo -e "\n=== Firewall ==="
sudo ufw status | head -5

echo -e "\n=== Kernel ==="
sysctl kernel.randomize_va_space kernel.yama.ptrace_scope 2>/dev/null

echo -e "\n=== Services ==="
for svc in fail2ban auditd unattended-upgrades cloudflared; do
  status=$(systemctl is-active $svc 2>/dev/null || echo "not found")
  echo "$svc: $status"
done

echo -e "\n=== Docker ==="
sudo docker info 2>/dev/null | grep -E "Live Restore|Default Runtime"

echo -e "\n=== Networks ==="
sudo docker network ls 2>/dev/null | grep -E "dev-|staging-|prod-"

echo -e "\n=== Secrets Permissions ==="
find secrets -name "*.txt" -exec ls -l {} \; 2>/dev/null | awk '{print $1, $NF}'
```

---

## Periodic Review

### Weekly

- [ ] Check fail2ban bans: `sudo fail2ban-client status sshd`
- [ ] Review auth logs: `./scripts/monitoring/logs.sh auth`
- [ ] Check disk usage: `./scripts/monitoring/disk-usage.sh`

### Monthly

- [ ] Review audit logs: `sudo ausearch -ts this-month -k sshd_config`
- [ ] Check for CVEs in installed packages
- [ ] Verify all containers have resource limits
- [ ] Rotate any leaked or old secrets

### Quarterly

- [ ] Rotate all secrets
- [ ] Review user access (remove unused accounts)
- [ ] Update SSH keys if needed
- [ ] Review and update firewall rules
- [ ] Test disaster recovery procedures
