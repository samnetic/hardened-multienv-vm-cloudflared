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
vim .env  # Set APP_NAME, DOMAIN, etc.

# Start the API
docker compose up -d

# View logs
docker compose logs -f

# Test locally
curl http://localhost:8000/health
curl http://localhost:8000/api/v1/hello
```

### 2. Add to Caddy

Edit `/srv/infrastructure/reverse-proxy/Caddyfile`:

```caddyfile
http://api.yourdomain.com {
  import security_headers
  reverse_proxy my-api-production:8000 {
    import proxy_headers
  }
}
```

Reload Caddy:

```bash
cd /srv/infrastructure/reverse-proxy
docker compose restart caddy
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
docker build -t my-api:latest .
docker run -p 8000:8000 my-api:latest
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
docker compose logs -f

# Filter by level
docker compose logs | grep ERROR
```

### Check Health

```bash
# Docker health status
docker inspect my-api-production | grep -A 10 Health

# Test health endpoint
curl http://localhost:8000/health
```

### Resource Usage

```bash
docker stats my-api-production
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
docker compose logs -f

# Check container status
docker compose ps

# Inspect container
docker inspect my-api-production
```

### Health check failing

```bash
# Test health endpoint manually
docker compose exec api curl http://localhost:8000/health

# View health status
docker inspect my-api-production | grep -A 10 Health
```

### Import errors

```bash
# Rebuild image
docker compose build --no-cache

# Check Python version
docker compose exec api python --version
```

## Production Checklist

Before deploying to production:

- [ ] Set strong secrets in `.env`
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
