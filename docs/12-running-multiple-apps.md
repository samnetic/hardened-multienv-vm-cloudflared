# Running Multiple Apps

Quick guide for hosting several applications on one VM.

## Adding a New App

```bash
# 1. Copy template
cp -r apps/_template apps/myapp

# 2. Edit configuration
cd apps/myapp
nano .env
nano compose.yml

# 3. Create secrets
../../scripts/secrets/create-secret.sh dev db_password

# 4. Deploy
sudo docker compose --compatibility up -d
```

## App Structure

Each app is self-contained:

```
apps/
├── myapp/
│   ├── compose.yml      # Container definition
│   ├── .env             # Environment config
│   └── .env.example     # Template for others
├── another-app/
│   └── ...
```

## Caddyfile Routing

Add routes for each app in `/srv/infrastructure/reverse-proxy/Caddyfile`:

```
http://myapp.yourdomain.com {
  import tunnel_only
  import security_headers
  reverse_proxy myapp-production:8080 {
    import proxy_headers
  }
}

http://staging-myapp.yourdomain.com {
  import tunnel_only
  import security_headers
  reverse_proxy myapp-staging:8080 {
    import proxy_headers
  }
}
```

Reload Caddy after changes:
```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose restart caddy
```

## Database Per App

Each app should have its own database container:

```yaml
# apps/myapp/compose.yml
services:
  app:
    image: myapp:latest
    depends_on:
      - db
    networks:
      - ${DOCKER_NETWORK}
      - myapp-internal

  db:
    image: postgres:16-alpine
    volumes:
      - myapp_data:/var/lib/postgresql/data
    networks:
      - myapp-internal
    # No ports exposed - only app can reach it

networks:
  myapp-internal:
    internal: true
  ${DOCKER_NETWORK}:
    external: true

volumes:
  myapp_data:
```

## Resource Limits

Set limits to prevent one app from killing others:

```yaml
deploy:
  resources:
    limits:
      cpus: '0.5'
      memory: 256M
```

**Guideline**: Total container limits should be < 75% of VM RAM.

## Quick Commands

```bash
# Start app
sudo docker compose --compatibility -f apps/myapp/compose.yml up -d

# View logs
sudo docker compose -f apps/myapp/compose.yml logs -f

# Restart
sudo docker compose -f apps/myapp/compose.yml restart

# Stop
sudo docker compose -f apps/myapp/compose.yml down

# Update
sudo docker compose -f apps/myapp/compose.yml pull
sudo docker compose --compatibility -f apps/myapp/compose.yml up -d
```

## Common Patterns

### App with Database

```yaml
services:
  app:
    image: myapp
    environment:
      - DATABASE_URL_FILE=/run/secrets/database_url
    group_add:
      - "1999"
    volumes:
      - /var/secrets/${ENVIRONMENT}/database_url.txt:/run/secrets/database_url:ro
    depends_on:
      - db

  db:
    image: postgres:16-alpine
    environment:
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
    group_add:
      - "1999"
    volumes:
      - db_data:/var/lib/postgresql/data
      - /var/secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
```

### App with Redis Cache

```yaml
services:
  app:
    image: myapp
    environment:
      - REDIS_URL=redis://redis:6379
    depends_on:
      - redis

  redis:
    image: redis:7-alpine
    command: redis-server --maxmemory 64mb --maxmemory-policy allkeys-lru
```

### Static Site

```yaml
services:
  site:
    image: nginx:alpine
    volumes:
      - ./public:/usr/share/nginx/html:ro
```

## Troubleshooting

**App not reachable?**
```bash
sudo docker compose ps                    # Is it running?
sudo docker compose logs                  # Any errors?
sudo docker network ls | grep web         # On right network?
```

**Database connection failed?**
```bash
sudo docker compose exec app ping db      # Can app reach db?
sudo docker compose logs db               # DB healthy?
```

**Out of memory?**
```bash
sudo docker stats                         # Who's using what?
./scripts/monitoring/status.sh       # System overview
```
