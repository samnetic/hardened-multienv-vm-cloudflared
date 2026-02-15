# Caddy Configuration Guide

Safe workflow for editing Caddy reverse proxy configuration without causing outages.

## Quick Start

### 1. Update Domain in Caddyfile

```bash
cd /srv/infrastructure/reverse-proxy
nano Caddyfile  # or vim

# Replace all instances of yourdomain.com with YOUR actual domain
# Example in vim: :%s/yourdomain.com/example.com/g
```

### 2. Validate and Apply Safely

```bash
# Use the safe update script (recommended)
sudo /opt/hosting-blueprint/scripts/update-caddy.sh

# Or manually:
# Validate syntax
sudo docker run --rm --network none -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile

# If valid, reload (zero downtime)
sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Critical Security Notes

- Keep `import tunnel_only` in every site block. It prevents origin IP bypass and container-to-container bypass.
- `hosting-caddy-origin` must exist (created by `sudo ./scripts/create-networks.sh`) and must remain the **first** network attached to the Caddy container (see `/srv/infrastructure/reverse-proxy/compose.yml`), otherwise `tunnel_only` allowlists can break.
- Don’t publish app container ports to the host. Route through Caddy on Docker networks.

## Safe Editing Workflow

### Method 1: Using update-caddy.sh (Safest)

```bash
# 1. Edit Caddyfile
cd /srv/infrastructure/reverse-proxy
nano Caddyfile

# 2. Run safe update script
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
```

This script:
- ✅ Backs up current config (timestamped)
- ✅ Validates syntax before applying
- ✅ Reloads with zero downtime
- ✅ Auto-rollback on failure
- ✅ Keeps last 10 backups

### Method 2: Manual Validation

```bash
cd /srv/infrastructure/reverse-proxy

# Edit
nano Caddyfile

# Validate syntax
sudo docker run --rm --network none -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile

# If valid, reload gracefully
sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# Check status
sudo docker compose ps
sudo docker compose logs caddy --tail 20
```

## Common Caddy Configurations

### Example 1: Add New App Subdomain

```caddyfile
# Add this to Caddyfile
http://myapp.yourdomain.com {
  import tunnel_only
  import security_headers

  reverse_proxy app-myapp:8080 {
    import proxy_headers
  }

  log {
    output file /data/logs/myapp-access.log {
      roll_size 20mb
      roll_keep 5
    }
    format json
  }
}
```

### Example 2: Static File Server

```caddyfile
http://static.yourdomain.com {
  import tunnel_only
  import security_headers
  root * /srv/static
  file_server
}
```

### Example 3: API with CORS

```caddyfile
http://api.yourdomain.com {
  import tunnel_only
  import security_headers

  # CORS headers for API
  header {
    Access-Control-Allow-Origin *
    Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS"
    Access-Control-Allow-Headers "Content-Type, Authorization"
  }

  reverse_proxy api-production:3000 {
    import proxy_headers
  }
}
```

### Example 4: Redirect Base Domain to www

```caddyfile
http://yourdomain.com {
  import tunnel_only
  redir https://www.yourdomain.com{uri} permanent
}

http://www.yourdomain.com {
  import tunnel_only
  import security_headers
  reverse_proxy app-production:80 {
    import proxy_headers
  }
}
```

## Expected Configuration Structure

After updating with your domain, your Caddyfile should have routes like:

```caddyfile
# DEV
http://dev-app.yourdomain.com → app-dev:80

# STAGING
http://staging-app.yourdomain.com → app-staging:80

# PRODUCTION
http://app.yourdomain.com → app-production:80

# Base domain
http://yourdomain.com → landing page or redirect

# Catch-all
http://*.yourdomain.com → 404 for unconfigured subdomains
```

## Testing Configuration

### 1. Syntax Validation

```bash
# Always validate before applying!
sudo docker run --rm --network none -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile
```

### 2. Test with curl (from VM or local)

```bash
# Test from VM
curl -H "Host: dev-app.yourdomain.com" http://localhost

# Test from outside (after DNS is configured)
curl https://dev-app.yourdomain.com
```

### 3. Check Logs

```bash
cd /srv/infrastructure/reverse-proxy

# Real-time logs
sudo docker compose logs caddy -f

# Last 50 lines
sudo docker compose logs caddy --tail 50

# Check for errors
sudo docker compose logs caddy | grep -i error
```

## Common Errors and Fixes

### Error: "directive not known"

**Cause:** Typo in directive name or incorrect indentation

**Fix:** Check Caddy v2 documentation - some directives changed from v1
- `proxy` → `reverse_proxy`
- `log` format changed
- `tls` → handled by Cloudflare in our setup

### Error: "opening listener: listen tcp :443: bind: address already in use"

**Cause:** Another service using port 443

**Fix:** We use HTTP-only behind Cloudflare Tunnel, so this shouldn't happen. Check:
```bash
sudo lsof -i :443
```

### Error: App not accessible

**Check:**
1. DNS CNAME points to tunnel: `dig dev-app.yourdomain.com`
2. Cloudflare proxy enabled (orange cloud)
3. Docker container running: `sudo docker ps | grep app-dev`
4. Container on correct network: `sudo docker inspect app-dev | grep Network`
5. Caddy logs for errors

## Rollback to Previous Config

```bash
# Automatic backups at
cd /srv/infrastructure/reverse-proxy/backups

# List backups
ls -lt

# Restore (replace TIMESTAMP with actual timestamp)
cp Caddyfile.YYYYMMDD_HHMMSS ../Caddyfile

# Reload
sudo docker compose restart caddy
```

## Best Practices

### ✅ DO:
- Always validate before applying
- Use the update-caddy.sh script
- Test in dev environment first
- Keep comments for future reference
- Use snippets for repeated config
- Monitor logs after changes

### ❌ DON'T:
- Edit without validation
- Restart container (use reload for zero downtime)
- Mix tabs and spaces (use spaces)
- Add HTTPS config (Cloudflare handles it)
- Expose admin API in production

## Indentation Rules

Caddy is **sensitive to indentation**:

```caddyfile
# CORRECT
http://yourdomain.com {
  import tunnel_only
  reverse_proxy app:80 {
    header_up X-Real-IP {remote_host}
  }
}

# WRONG (inconsistent indentation)
http://yourdomain.com {
import tunnel_only
reverse_proxy app:80 {
  header_up X-Real-IP {remote_host}
  }
}
```

**Rule:** Use 2 spaces per indent level, be consistent.

## Zero Downtime Reload

Caddy supports graceful reloads:

```bash
# This does NOT drop connections
sudo docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

# vs. restart (WILL drop connections)
sudo docker compose restart caddy  # Only use if reload fails
```

## Monitoring Caddy

```bash
# Is Caddy running?
sudo docker compose ps caddy

# Resource usage
sudo docker stats caddy --no-stream

# Access logs (JSON format)
sudo docker compose exec caddy cat /data/logs/production-access.log | tail -20

# Error logs
sudo docker compose logs caddy | grep ERROR
```

## Next Steps

1. Update Caddyfile with yourdomain.com domain
2. Validate and reload: `sudo /opt/hosting-blueprint/scripts/update-caddy.sh`
3. Create your first app in `apps/` directory
4. Point subdomain to tunnel in Cloudflare dashboard
5. Test: `curl https://dev-app.yourdomain.com`

## Reference

- [Caddy v2 Docs](https://caddyserver.com/docs/)
- [Caddyfile Directives](https://caddyserver.com/docs/caddyfile/directives)
- [reverse_proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
- [Common Patterns](https://caddyserver.com/docs/caddyfile/patterns)
