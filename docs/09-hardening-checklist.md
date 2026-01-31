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
```

### Checklist

- [ ] unattended-upgrades installed and running
- [ ] Security updates enabled
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
  "icc": false
}
```

### Verify Container Defaults

```bash
# Check a running container
docker inspect mycontainer | jq '.[0].HostConfig.SecurityOpt'
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
docker network ls | grep -E "dev-|staging-|prod-"
docker network inspect staging-backend | jq '.[0].Internal'
docker network inspect prod-backend | jq '.[0].Internal'
```

### Checklist

- [ ] dev-backend is NOT internal (bridge, for local dev access)
- [ ] staging-backend IS internal
- [ ] prod-backend IS internal
- [ ] Apps and databases on separate networks

---

## User Management

### Verify Users

```bash
# Check sysadmin has sudo
groups sysadmin

# Check appmgr has docker but NOT sudo
groups appmgr

# Check no password login
sudo cat /etc/shadow | grep -E "sysadmin|appmgr"
# Should show ! or * (no password)
```

### Checklist

- [ ] sysadmin user exists with sudo
- [ ] appmgr user exists WITHOUT sudo
- [ ] appmgr has docker group
- [ ] No password authentication (keys only)
- [ ] Root direct login disabled

---

## Secrets Management

### Verify Permissions

```bash
ls -la secrets/*/
# All .txt files should be 600
```

### Checklist

- [ ] Secret files have 600 permissions
- [ ] secrets/ directory gitignored
- [ ] No secrets in environment variables (use _FILE pattern)
- [ ] Different secrets per environment

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
docker info 2>/dev/null | grep -E "Live Restore|Default Runtime"

echo -e "\n=== Networks ==="
docker network ls 2>/dev/null | grep -E "dev-|staging-|prod-"

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
