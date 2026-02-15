# Python FastAPI Example

Production-ready FastAPI application with security best practices.

## What This Demonstrates

- ✅ FastAPI REST API with async support
- ✅ Health check endpoint
- ✅ Environment-based configuration
- ✅ Structured logging
- ✅ Docker security (no-new-privileges, resource limits)
- ✅ Non-root user
- ✅ Multi-stage Docker build

## Quick Start

### 1. Deploy to Production

```bash
# Copy example to production location
cp -r apps/examples/python-fastapi /srv/apps/production/my-api

cd /srv/apps/production/my-api

# Configure environment
cp .env.example .env
vim .env  # Set APP_NAME, DOCKER_NETWORK, IMAGE, etc.

# GitOps-friendly: deploy a pre-built image (no host ports published)
sudo docker compose pull
sudo docker compose --compatibility up -d

# View logs
sudo docker compose logs -f

# Smoke test from inside the container
sudo docker compose exec api curl -f http://localhost:8000/health
sudo docker compose exec api curl -f http://localhost:8000/api/v1/hello
```

Optional: local/VM-side build + loopback port (convenience only, not GitOps-safe):

```bash
sudo docker compose --compatibility -f compose.yml -f compose.local.yml up -d --build
curl http://127.0.0.1:8000/health
```

### 2. Add to Caddy

Edit `/srv/infrastructure/reverse-proxy/Caddyfile`:

```caddyfile
http://api.yourdomain.com {
  import tunnel_only
  import security_headers
  reverse_proxy my-api-production:8000 {
    import proxy_headers
  }
}
```

Reload Caddy:

```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose restart caddy
```

### 3. Add DNS

In Cloudflare dashboard, add CNAME:
- **Name:** `api`
- **Target:** `<your-tunnel-id>.cfargotunnel.com`
- **Proxy:** ON (orange cloud)

### 4. Test

```bash
curl https://api.yourdomain.com/health
curl https://api.yourdomain.com/api/v1/hello
curl https://api.yourdomain.com/docs  # OpenAPI docs
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check (for Docker) |
| GET | `/api/v1/hello` | Hello world endpoint |
| GET | `/api/v1/items` | List items example |
| GET | `/docs` | OpenAPI documentation |
| GET | `/redoc` | ReDoc documentation |

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `APP_NAME` | Yes | - | Application name |
| `ENVIRONMENT` | Yes | - | `production` or `staging` |
| `DOCKER_NETWORK` | Yes | - | `prod-web` or `staging-web` |
| `IMAGE` | No | `ghcr.io/your-org/my-api:1.0.0` | Container image to deploy |
| `LOG_LEVEL` | No | `INFO` | Logging level |
| `ALLOWED_ORIGINS` | No | `*` | CORS allowed origins |

## Development

### Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Run locally
uvicorn src.main:app --reload --host 0.0.0.0 --port 8000

# Test
curl http://localhost:8000/health
```

### Build Docker Image

```bash
# Recommended: use the provided override for local builds
sudo docker compose -f compose.yml -f compose.local.yml build
sudo docker compose --compatibility -f compose.yml -f compose.local.yml up -d
```

## Security Features

This example includes production-ready security:

- ✅ **Non-root user** - Runs as UID 1000
- ✅ **no-new-privileges** - Prevents privilege escalation
- ✅ **Dropped capabilities** - ALL capabilities dropped
- ✅ **Resource limits** - 0.5 CPU, 512MB RAM
- ✅ **Health checks** - Automatic restart on failure
- ✅ **CORS configuration** - Configurable allowed origins
- ✅ **Structured logging** - JSON logs for production

## Monitoring

### View Logs

```bash
sudo docker compose logs -f

# Filter by level
sudo docker compose logs | grep ERROR
```

### Check Health

```bash
# Docker health status
sudo docker inspect my-api-production | grep -A 10 Health

# Test health endpoint
curl http://localhost:8000/health
```

### Resource Usage

```bash
sudo docker stats my-api-production
```

## Extending

### Add Database

Add PostgreSQL to `compose.yml`:

```yaml
services:
  api:
    # ... existing config ...
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    container_name: ${APP_NAME}-db
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_USER=${DB_USER}
      - POSTGRES_DB=${DB_NAME}
    volumes:
      - db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  db_data:
```

### Add Redis Cache

```yaml
redis:
  image: redis:7-alpine
  container_name: ${APP_NAME}-redis
  restart: unless-stopped
  networks:
    - ${DOCKER_NETWORK}
  security_opt:
    - no-new-privileges:true
  command: redis-server --requirepass ${REDIS_PASSWORD}
  healthcheck:
    test: ["CMD", "redis-cli", "ping"]
    interval: 10s
    timeout: 5s
    retries: 5
```

## Troubleshooting

### Container not starting

```bash
# Check logs
sudo docker compose logs -f

# Check container status
sudo docker compose ps

# Inspect container
sudo docker inspect my-api-production
```

### Health check failing

```bash
# Test health endpoint manually
sudo docker compose exec api curl http://localhost:8000/health

# View health status
sudo docker inspect my-api-production | grep -A 10 Health
```

### Import errors

```bash
# If you're using the local build override:
sudo docker compose -f compose.yml -f compose.local.yml build --no-cache

# If you're using a pre-built image:
sudo docker compose pull
sudo docker compose --compatibility up -d

# Check Python version
sudo docker compose exec api python --version
```

## Production Checklist

Before deploying to production:

- [ ] Set strong secrets (prefer `/var/secrets/*` file mounts; avoid committing secrets in `.env`)
- [ ] Configure `ALLOWED_ORIGINS` for CORS
- [ ] Set `LOG_LEVEL=WARNING` (not DEBUG)
- [ ] Test health endpoint returns 200
- [ ] Verify resource limits are appropriate
- [ ] Add monitoring alerts
- [ ] Set up log aggregation
- [ ] Configure backups (if using database)
- [ ] Test rollback procedure

## Resources

- FastAPI Docs: https://fastapi.tiangolo.com
- Pydantic: https://pydantic-docs.helpmanual.io
- Uvicorn: https://www.uvicorn.org
