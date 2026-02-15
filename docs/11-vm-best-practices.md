# VM Best Practices

Comprehensive guide for running a production VM with multiple applications.

## Resource Planning

### Sizing Your VM

| Workload | RAM | CPU | Disk | Notes |
|----------|-----|-----|------|-------|
| 1-2 small apps | 2GB | 1 vCPU | 40GB | Minimum viable |
| 3-5 apps | 4GB | 2 vCPU | 80GB | Recommended |
| 5-10 apps + DB | 8GB | 4 vCPU | 160GB | Comfortable |
| Heavy workloads | 16GB+ | 8+ vCPU | 320GB+ | Scale as needed |

### Memory Allocation

Reserve memory for the system and Docker:

```
Total RAM: 8GB
├── System/OS:      1GB (reserved)
├── Docker daemon:  0.5GB
├── Caddy:          128MB
├── Cloudflared:    64MB
└── Available for apps: ~6.3GB
```

**Rule of thumb**: Don't allocate more than 75% of RAM to containers.

### Container Resource Limits

Always set limits in compose.yml:

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: '1.0'      # Max 1 CPU core
          memory: 512M      # Max 512MB RAM
        reservations:
          cpus: '0.25'      # Guaranteed 0.25 CPU
          memory: 128M      # Guaranteed 128MB RAM
```

## Application Architecture

### One Service Per Container

**Good:**
```yaml
services:
  app:
    image: myapp:latest
  db:
    image: postgres:16
  redis:
    image: redis:7
```

**Bad:**
```yaml
services:
  everything:
    # App + DB + Redis all in one container
    # Hard to scale, update, debug
```

### Database Placement

| Option | Pros | Cons |
|--------|------|------|
| **Same VM (container)** | Simple, low latency | Shares resources |
| **Managed DB service** | Scalable, backups handled | Cost, latency |
| **Separate VM** | Isolation | Complexity |

For most small-medium projects, **database container on the same VM** is fine.

### Shared vs Dedicated Databases

**Dedicated (Recommended for production):**
```
myapp-production → myapp-db-production
myapp-staging → myapp-db-staging
```

**Shared (OK for non-critical):**
```
dev-apps → shared-dev-db (multiple databases inside)
```

## Networking

### Network Isolation Matrix

```
                    dev-web   dev-back   staging-web   staging-back   prod-web   prod-back
Caddy               ✓         -          ✓             -              ✓          -
App containers      ✓         ✓          ✓             ✓              ✓          ✓
Databases           -         ✓          -             ✓              -          ✓
External access     ✓         ✓*         ✓             -              ✓          -

* dev-backend accessible for local development
```

### Port Conflicts

Containers don't expose ports externally (Caddy handles routing), but watch for internal conflicts:

```yaml
# These are fine - different containers
app1:
  ports: []  # No host ports
app2:
  ports: []  # No host ports

# Internal ports don't conflict because containers are isolated
```

### DNS for Containers

Containers on the same network can reach each other by name:

```yaml
# In app container
DATABASE_HOST=myapp-db-staging  # Container name, not localhost
REDIS_HOST=myapp-redis-staging
```

## Storage

### Volume Strategies

| Type | Use Case | Example |
|------|----------|---------|
| **Named volumes** | Database data | `postgres_data:/var/lib/postgresql/data` |
| **Bind mounts** | Config files, secrets | `./secrets:/run/secrets:ro` |
| **tmpfs** | Temporary data | `tmpfs: ["/tmp"]` |

### Backup Strategy

```bash
# Database backup (daily)
sudo docker exec myapp-db pg_dump -U user dbname > backup.sql

# Volume backup (weekly)
./scripts/maintenance/backup-volumes.sh

# Full VM snapshot (before major changes)
# Use your cloud provider's snapshot feature
```

### Disk Usage Monitoring

```bash
# Check usage
./scripts/monitoring/disk-usage.sh

# Set up alerts (already in cron)
# Warning at 75%, critical at 90%
```

## Logging

### Log Levels by Environment

| Environment | Log Level | Retention |
|-------------|-----------|-----------|
| Dev | DEBUG | 3 days |
| Staging | INFO | 7 days |
| Production | WARN | 30 days |

### Viewing Logs

```bash
# All container logs
./scripts/monitoring/logs.sh docker

# Specific container
./scripts/monitoring/logs.sh docker myapp-production

# Follow logs
./scripts/monitoring/logs.sh docker myapp-production --follow

# Security events
./scripts/monitoring/logs.sh security
```

### Log Rotation

Docker logs are rotated automatically (configured in daemon.json):
```json
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  }
}
```

System logs rotated by journald (30 days, 500MB max).

## Health Checks

### Container Health Checks

Always define health checks:

```yaml
services:
  app:
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### What to Check

| Service | Health Endpoint | What It Verifies |
|---------|-----------------|------------------|
| Web app | `/health` | App is responding |
| API | `/api/health` | API + DB connection |
| Database | `pg_isready` | Accepting connections |
| Redis | `redis-cli ping` | Responding to commands |

### Monitoring Health

```bash
# Quick status
./scripts/monitoring/status.sh

# Container health
sudo docker ps --format "table {{.Names}}\t{{.Status}}"

# Detailed health
sudo docker inspect --format='{{.State.Health.Status}}' container_name
```

## Updates and Maintenance

### Update Schedule

| What | Frequency | How |
|------|-----------|-----|
| Security patches | Auto-daily | unattended-upgrades |
| cloudflared | Auto-daily | `hosting-cloudflared-upgrade.timer` (installed by `scripts/install-cloudflared.sh`) |
| Container images | Weekly/PR | `sudo docker compose pull` |
| Base OS upgrade | Annually | Manual, with backup |

### Zero-Downtime Updates

For critical apps:

```bash
# 1. Pull new image
sudo docker compose pull

# 2. Scale up (if using replicas)
sudo docker compose up -d --scale app=2

# 3. Wait for health check
sleep 30

# 4. Scale down old
sudo docker compose up -d --scale app=1
```

For simpler setups:
```bash
# Caddy handles brief downtime gracefully
sudo docker compose pull && sudo docker compose up -d
```

### Maintenance Windows

Schedule maintenance for low-traffic periods:

```bash
# Auto-reboot for kernel updates: 02:30 (configured in unattended-upgrades)
# Docker cleanup: Sundays 03:00 (configured in cron)
# Volume backups: Daily 02:00 (if enabled in cron)
```

## Security Practices

### Regular Tasks

**Daily (automated):**
- Security updates installed
- Disk usage checked
- Logs rotated

**Weekly:**
- Review fail2ban bans: `sudo fail2ban-client status sshd`
- Check Docker image updates
- Review access logs

**Monthly:**
- Rotate any temporary credentials
- Review user access list
- Check for unused containers/images
- Review audit logs

**Quarterly:**
- Rotate all secrets
- Review firewall rules
- Update SSH keys if needed
- Security scan containers

### Before Deploying New Apps

Checklist:
- [ ] Container runs as non-root user
- [ ] Resource limits defined
- [ ] Health check configured
- [ ] Secrets via file mounts (not env vars)
- [ ] Connected to correct network
- [ ] Logs configured properly

## Troubleshooting Patterns

### Container Won't Start

```bash
# Check logs
sudo docker compose logs app

# Check resource limits
sudo docker stats --no-stream

# Check disk space
df -h

# Check if port conflicts (rare with our setup)
sudo docker ps -a
```

### App Unreachable

```bash
# Is container running?
sudo docker compose ps

# Is it healthy?
sudo docker inspect --format='{{.State.Health.Status}}' container

# Can Caddy reach it?
sudo docker compose -f infra/reverse-proxy/compose.yml logs caddy

# Is Cloudflare tunnel up?
sudo systemctl status cloudflared
```

### High Resource Usage

```bash
# Find resource hogs
sudo docker stats

# Check system resources
htop

# Check what's filling disk
./scripts/monitoring/disk-usage.sh
```

### Database Connection Issues

```bash
# Is database container running?
sudo docker compose ps db

# Can app container reach database?
sudo docker compose exec app ping db-container-name

# Check database logs
sudo docker compose logs db
```

## Scaling Considerations

### When to Scale Vertically (Bigger VM)

- RAM consistently > 80% used
- CPU consistently > 70% used
- Database needs more resources
- Simple solution, no architecture changes

### When to Scale Horizontally (More VMs)

- Need high availability
- Geographic distribution needed
- Workload can be split (microservices)
- Database needs dedicated resources

### When to Use Managed Services

Consider moving to managed services when:
- Database management becomes burden
- Need automated backups with point-in-time recovery
- Compliance requirements demand it
- Team doesn't have DB expertise

## Cost Optimization

### Right-Size Resources

```bash
# Monitor actual usage over time
sudo docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Reduce limits for underutilized containers
# Increase for those hitting limits
```

### Clean Up Regularly

```bash
# Remove unused resources
./scripts/maintenance/docker-cleanup.sh

# Full cleanup (careful in production)
sudo docker system prune -a --volumes
```

### Reserve Instances

For long-running VMs, use reserved/committed instances from your cloud provider (30-50% savings).

## Disaster Recovery

### Backup Checklist

- [ ] Database dumps (daily)
- [ ] Docker volumes (weekly)
- [ ] VM snapshots (before major changes)
- [ ] Secrets backed up securely
- [ ] Configuration in git

### Recovery Steps

1. **Provision new VM** with same specs
2. **Clone git repo** with all configs
3. **Run setup.sh** to configure
4. **Restore secrets** from secure backup
5. **Restore database** from dump
6. **Restore volumes** from backup
7. **Update DNS** if IP changed
8. **Verify** all services working

### Test Recovery

Quarterly: Practice recovery on a test VM to ensure backups work.
