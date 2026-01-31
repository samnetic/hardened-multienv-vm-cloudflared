# Caddy Reverse Proxy

HTTP reverse proxy for routing Cloudflare Tunnel traffic to Docker containers.

## Overview

- **Purpose**: Route HTTP traffic from Cloudflare Tunnel to Docker apps
- **HTTPS**: Handled by Cloudflare Tunnel (Caddy runs HTTP-only)
- **Routing**: Subdomain-based routing (`staging-app.domain.com`, `app.domain.com`)

## Quick Start

```bash
# Copy environment file
cp .env.example .env

# Edit with your domain
nano .env

# Update Caddyfile with your domain
nano Caddyfile
# Replace all instances of "yourdomain.com" with your actual domain

# Start Caddy
docker compose up -d

# View logs
docker compose logs -f

# Test configuration
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
```

## Configuration

### Caddyfile Structure

The Caddyfile uses HTTP-only because Cloudflare Tunnel handles HTTPS:

```caddyfile
http://staging-app.yourdomain.com {
  reverse_proxy app-staging:80
}

http://app.yourdomain.com {
  reverse_proxy app-production:80
}
```

### Adding New Apps

1. Add a new block to Caddyfile:

```caddyfile
http://new-app.yourdomain.com {
  import security_headers
  reverse_proxy new-app-container:port {
    import proxy_headers
  }
}
```

2. Reload Caddy:

```bash
docker compose restart caddy
```

## Security

Caddy is hardened with:
- ✅ `no-new-privileges` - Prevent privilege escalation
- ✅ `cap_drop: ALL` - Drop all Linux capabilities
- ✅ `cap_add: NET_BIND_SERVICE` - Only allow binding to port 80
- ✅ Security headers (HSTS, CSP, X-Frame-Options)
- ✅ Resource limits (0.5 CPU, 256MB RAM)

## Networks

Caddy connects to:
- `staging-web` - Staging environment apps
- `prod-web` - Production environment apps
- `monitoring` (optional) - For Prometheus metrics

## Troubleshooting

### Check if Caddy is running

```bash
docker compose ps
docker compose logs caddy
```

### Validate Caddyfile syntax

```bash
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
```

### Test app connectivity

```bash
# From inside Caddy container
docker compose exec caddy wget -O- http://app-staging:80
```

### View access logs

```bash
# Inside container
docker compose exec caddy tail -f /data/logs/staging-access.log
docker compose exec caddy tail -f /data/logs/production-access.log
```

### Reload configuration without downtime

```bash
docker compose restart caddy
```

## Files

- `compose.yml` - Docker Compose configuration (2025 syntax, NO version field)
- `Caddyfile` - Caddy routing configuration
- `.env` - Environment variables (your domain)
- `compose.override.yml.example` - Local development overrides

## References

- [Caddy Documentation](https://caddyserver.com/docs/)
- [Caddyfile Syntax](https://caddyserver.com/docs/caddyfile)
- [Reverse Proxy Guide](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy)
