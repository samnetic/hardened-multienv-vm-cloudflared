# Security Hardening Guide

Security best practices and hardening measures for production deployments.

---

## Security Layers

This blueprint implements defense in depth:

1. **Network** - Cloudflare tunnel, UFW firewall
2. **OS** - SSH hardening, fail2ban, user separation
3. **Container** - Docker 2025 security standards
4. **Application** - Security headers, rate limiting

---

## SSH Hardening (Applied by setup-vm.sh)

### Configuration: `/etc/ssh/sshd_config`

```bash
# Disable root login
PermitRootLogin no

# Only key-based authentication
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no

# Only allow specific users
AllowUsers sysadmin appmgr

# Strong ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
```

### fail2ban Protection

Automatically bans IPs after failed SSH attempts:
```bash
# Check status
sudo fail2ban-client status sshd

# View banned IPs
sudo fail2ban-client status sshd | grep "Banned IP"
```

---

## Firewall (UFW)

### Initial Configuration

```bash
# Default policies
sudo ufw default deny incoming
sudo ufw default allow outgoing
```

### After Cloudflare Tunnel Setup

**Lock down to Cloudflare IPs only:**
```bash
# Download Cloudflare IP ranges
curl -s https://www.cloudflare.com/ips-v4 -o /tmp/cf_ips_v4

# Allow only Cloudflare to web ports
while read ip; do sudo ufw allow from $ip to any port 80,443 proto tcp; done < /tmp/cf_ips_v4

# Remove public SSH access
sudo ufw delete allow OpenSSH
```

### Verify

```bash
sudo ufw status verbose
# Port 22 should NOT be listed
# Only Cloudflare IPs should access 80/443
```

---

## Docker Security (2025 Standards)

### Container Hardening

All containers in this blueprint use:

```yaml
security_opt:
  - no-new-privileges:true  # Prevent privilege escalation
cap_drop:
  - ALL  # Drop all Linux capabilities
cap_add:
  - NET_BIND_SERVICE  # Add only needed caps
read_only: true  # Immutable filesystem (where possible)
```

### Resource Limits

Prevent resource abuse:
```yaml
deploy:
  resources:
    limits:
      cpus: '1.0'
      memory: 512M
```

### Non-Root User

Run as non-root in Dockerfile:
```dockerfile
RUN addgroup -S nodejs && adduser -S nodejs -G nodejs
USER nodejs
```

---

## User Separation

### sysadmin (System Administrator)
- ✅ sudo access
- ✅ System updates
- ✅ Firewall configuration
- ❌ No app deployments

### appmgr (Application Manager)
- ✅ Docker access
- ✅ App deployments
- ✅ Log viewing
- ❌ No sudo
- ❌ No system changes

---

## Network Isolation

### Docker Networks

**Production:**
- `prod-web` - Public-facing apps
- `prod-backend` - Databases (internal only, no internet)

**Staging:**
- `staging-web` - Public-facing apps
- `staging-backend` - Databases (internal only)

**Benefits:**
- Staging can't access production
- Databases not exposed to internet
- Apps can only talk to their environment

---

## Security Headers (Caddy)

Applied automatically via Caddyfile:

```caddyfile
(security_headers) {
  header {
    Strict-Transport-Security "max-age=31536000;"  # HSTS
    X-Frame-Options "DENY"  # Clickjacking protection
    X-Content-Type-Options "nosniff"  # MIME sniffing protection
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    -Server  # Hide server version
  }
}
```

---

## Secrets Management

We use **file-based secrets** instead of environment variables. See [06-secrets-management.md](06-secrets-management.md) for full details.

### Quick Reference

```bash
# Create secret
./scripts/secrets/create-secret.sh staging db_password

# List secrets
./scripts/secrets/list-secrets.sh

# Rotate secret
./scripts/secrets/rotate-secret.sh staging db_password
```

### In compose.yml

```yaml
environment:
  - DATABASE_PASSWORD_FILE=/run/secrets/db_password
volumes:
  - ../../secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
```

### Rules

- **Never** commit secrets to git (gitignored by default)
- **Never** use same secrets across environments
- **Always** use file-based pattern (not env vars)
- **Rotate** secrets quarterly or when team members leave

---

## Audit Logging

### Docker Events

Track container lifecycle:
```bash
docker events --format '{{json .}}' | tee -a /var/log/docker-events.log
```

### Deployment Logs

Use `scripts/deploy-app.sh` which logs to:
```bash
/var/log/deployments.log
```

### SSH Access Logs

```bash
sudo journalctl -u sshd --since "1 day ago"
```

---

## Security Checklist

### Before Production

- [ ] SSH keys only (no password auth)
- [ ] fail2ban enabled
- [ ] UFW locked to Cloudflare IPs
- [ ] Port 22 closed to public
- [ ] All containers use `no-new-privileges`
- [ ] Resource limits on all containers
- [ ] Secrets in .env files (gitignored)
- [ ] Separate secrets for staging/production
- [ ] Health checks on all apps
- [ ] Caddy security headers enabled
- [ ] Docker networks isolated

### Regular Maintenance

- [ ] Update system packages weekly
- [ ] Update Docker images when available
- [ ] Review fail2ban logs
- [ ] Check UFW rules
- [ ] Rotate secrets quarterly
- [ ] Review Docker container security
- [ ] Monitor cloudflared logs

---

## Common Security Issues

### Exposed Secrets

**Problem:** Secrets committed to git

**Solution:**
```bash
# Remove from history
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch .env" \
  --prune-empty --tag-name-filter cat -- --all

# Rotate all exposed secrets immediately
```

### Container Running as Root

**Problem:** App runs as root user

**Solution:**
```dockerfile
# Add to Dockerfile
RUN addgroup -S appuser && adduser -S appuser -G appuser
USER appuser
```

### Open Firewall

**Problem:** Port 22 accessible from internet

**Solution:**
```bash
sudo ufw status
sudo ufw delete allow OpenSSH
```

---

## Security Monitoring

### Daily Checks

```bash
# Failed SSH attempts
sudo journalctl -u sshd --since "1 day ago" | grep "Failed"

# Container restarts (possible attacks)
docker ps --format "table {{.Names}}\t{{.Status}}"

# Firewall hits
sudo tail /var/log/ufw.log
```

### Weekly Checks

```bash
# System updates
sudo apt update && sudo apt list --upgradable

# Docker vulnerabilities (use trivy or similar)
# fail2ban statistics
sudo fail2ban-client status
```

---

## Incident Response

### Suspected Compromise

1. **Isolate:**
   ```bash
   sudo ufw deny from <suspicious-ip>
   ```

2. **Investigate:**
   ```bash
   sudo journalctl --since "1 hour ago" | grep <ip>
   ```

3. **Rotate secrets:**
   - Change all passwords
   - Regenerate API keys
   - Update .env files

4. **Review:**
   - Check docker logs
   - Review fail2ban
   - Audit user actions

---

## Related Docs

- [06-secrets-management.md](06-secrets-management.md) - File-based secrets
- [09-hardening-checklist.md](09-hardening-checklist.md) - Quick verification checklist
- [10-user-management.md](10-user-management.md) - Adding/removing users

## References

- [OWASP Docker Security](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html)
- [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker)
- [SSH Hardening Guide](https://www.ssh.com/academy/ssh/sshd_config)
