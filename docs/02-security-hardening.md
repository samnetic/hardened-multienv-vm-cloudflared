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

With Cloudflare Tunnel, you generally do **not** need any inbound firewall allows (HTTP/HTTPS is delivered over the tunnel).

**Recommended (zero inbound ports):**
```bash
# Remove direct SSH access (once tunnel SSH is verified)
sudo ufw delete allow OpenSSH
sudo ufw delete limit OpenSSH
```

### Verify

```bash
sudo ufw status verbose
# Port 22 should NOT be listed
# No inbound ALLOW rules are needed for Tunnel-only setups
```

---

## Tunnel-Only Origin Enforcement (Caddy)

This blueprint enforces “tunnel-only” origin access with defense in depth:

- **Ports:** UFW closes 80/443 (and optionally 22), so the VM does not accept inbound traffic directly.
- **Bind:** The reverse proxy publishes only to `127.0.0.1:80` (cloudflared connects locally).
- **Reject bypass:** Caddy denies any request not coming from the host NAT gateway of `hosting-caddy-origin` (pinned to `10.250.0.1`) or loopback. This prevents container-to-container bypasses if an app container is compromised.
- **Idempotency:** `scripts/finalize-tunnel.sh` writes `/etc/hosting-blueprint/tunnel-only.enabled`. Re-running `scripts/setup-vm.sh` will detect this and will not re-open inbound ports.

If you get unexpected `403` responses from Caddy, see `docs/05-troubleshooting.md`.

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
- ✅ Emergency/manual deployments (via sudo)

By default, `sysadmin` sudo requires a local password (SSH remains key-only).

### appmgr (Application Manager)
- ✅ CI/CD deployments (restricted)
- ✅ `hosting sync|deploy|status` only (no shell)
- ❌ Docker group access
- ❌ Interactive SSH shell
- ❌ System changes

### Important: Docker Group == Root

On a Docker host, membership in the `docker` group is effectively **root-equivalent** because Docker can mount the host filesystem and start privileged containers.

This blueprint avoids giving `appmgr` docker access. Instead, `appmgr` is restricted via `sshd ForceCommand` and a sudo allowlist to a root-owned deploy tool.

Treat `appmgr` and its SSH key as **high privilege** (it can trigger deployments).

Recommended mitigations:

- Use a dedicated CI/CD deploy key (don’t reuse your personal key).
- Protect SSH with Cloudflare Access + Service Tokens (machine-to-machine).
- Restrict CI with a forced command (enabled by default in this blueprint).
- Prefer a separate VPS for monitoring/control-plane tools (Grafana admin, etc.).

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
group_add:
  - "1999" # hosting-secrets (so non-root containers can read /var/secrets/*/*.txt)
volumes:
  - /var/secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
```

### Rules

- **Never** commit secrets to git (use `/var/secrets`)
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
- [ ] UFW inbound closed (tunnel-only)
- [ ] Port 22 closed to public
- [ ] All containers use `no-new-privileges`
- [ ] Resource limits on all containers
- [ ] Secrets stored as files in `/var/secrets` (not in git)
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
sudo docker ps --format "table {{.Names}}\t{{.Status}}"

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
   - Check sudo docker logs
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
