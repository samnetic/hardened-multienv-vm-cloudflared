# App Template

Generic template for deploying Docker applications with 2025 security standards.

## Quick Start

### 1. Copy Template

```bash
# Copy this template for your new app
cp -r apps/_template apps/my-new-app
cd apps/my-new-app
```

### 2. Configure Environment

```bash
# Copy environment file
cp .env.example .env

# Edit with your values
nano .env
```

**Key variables to set:**
- `ENVIRONMENT` - `staging` or `production`
- `APP_NAME` - Your app name (lowercase, no spaces)
- `DOCKER_NETWORK` - `staging-web` or `prod-web`
- `APP_PORT` - Port your app listens on

### 3. Update compose.yml

Edit `compose.yml` and update:
- `image:` - Your Docker image name (pin a version tag or digest; avoid `:latest`)
- `build:` - Discouraged in production; the hardened GitOps deploy policy blocks `build:` by default
- `healthcheck:` - Your app's health endpoint
- `environment:` - App-specific variables

### 4. Deploy

```bash
# Pull image (recommended; GitOps expects pre-built images)
sudo docker compose pull
#
# If you really need on-VM builds (not recommended):
# - Set ALLOW_BUILD=1 in /etc/hosting-blueprint/deploy-policy.env (root-owned)
# - Then: sudo docker compose build

# Start app
sudo docker compose --compatibility up -d

# View logs
sudo docker compose logs -f

# Check status
sudo docker compose ps
```

### 5. Add to Caddy

Edit `/srv/infrastructure/reverse-proxy/Caddyfile` and add:

```caddyfile
http://my-app.yourdomain.com {
  import tunnel_only
  import security_headers
  reverse_proxy app-my-app:3000 {
    import proxy_headers
  }
}
```

Restart Caddy:

```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose restart caddy
```

---

## Security Features

This template includes 2025 Docker security standards:

✅ **no-new-privileges** - Prevents privilege escalation
✅ **cap_drop: ALL** - Drops all Linux capabilities by default
✅ **Resource limits** - CPU and memory limits prevent abuse
✅ **Health checks** - Automatic restart on failure
✅ **Least privilege** - Add only required capabilities

---

## Customization

### Add Database

```yaml
services:
  app:
    # ... existing config ...
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    container_name: ${APP_NAME}-db
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_DB=${DB_NAME}
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  db_data:
```

### Add Capabilities

If your app needs specific Linux capabilities:

```yaml
cap_add:
  - NET_BIND_SERVICE  # Bind to ports < 1024
  - CHOWN             # Change file ownership
```

### Enable Read-Only Filesystem

For maximum security (if your app doesn't write files):

```yaml
read_only: true
tmpfs:
  - /tmp
  - /var/run
```

---

## Environment Variables

### Required

- `ENVIRONMENT` - `staging` or `production`
- `APP_NAME` - Your app name
- `DOCKER_NETWORK` - Network to join (`staging-web` or `prod-web`)
- `APP_PORT` - Port app listens on

### Optional

- `NODE_ENV` - Node.js environment
- Add your app-specific variables in `.env`

---

## Health Checks

Health check examples for different languages:

### Node.js

```yaml
healthcheck:
  test: ["CMD", "node", "-e", "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"]
```

### Python

```yaml
healthcheck:
  test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"]
```

### wget/curl

```yaml
healthcheck:
  test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/health"]
```

---

## Networks

### Staging

```bash
DOCKER_NETWORK=staging-web
```

Your app will be accessible at: `https://staging-app.yourdomain.com`

### Production

```bash
DOCKER_NETWORK=prod-web
```

Your app will be accessible at: `https://app.yourdomain.com`

---

## Troubleshooting

### Container not starting

```bash
# Check logs
sudo docker compose logs -f

# Check container status
sudo docker compose ps

# Inspect container
sudo docker inspect app-${ENVIRONMENT}
```

### Health check failing

```bash
# Test health endpoint manually
sudo docker compose exec app wget -O- http://localhost:3000/health

# View health status
sudo docker inspect app-${ENVIRONMENT} | grep -A 10 Health
```

### Permission errors

Check if your app needs additional capabilities:

```bash
# View app logs for permission errors
sudo docker compose logs app | grep -i permission
```

---

## Best Practices

1. **Always set resource limits** - Prevents one app from starving others
2. **Use health checks** - Automatic recovery from failures
3. **Run as non-root** - Add `user: "1000:1000"` if possible
4. **Minimize capabilities** - Only add what's absolutely needed
5. **Use file-based secrets** - Put secrets in `/var/secrets/<env>/*.txt` and mount them read-only
6. **Test in staging first** - Always deploy to staging before production

---

## Example Apps

See working examples:
- `apps/examples/hello-world/` - Static nginx site
- `apps/examples/simple-api/` - Node.js Express API
