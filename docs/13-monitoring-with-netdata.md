# Monitoring with Netdata

Real-time monitoring for your VM and Docker containers.

## Security Note (Read This)

Netdata can require elevated access (e.g., `SYS_ADMIN`, Docker socket) to provide deep container/system visibility. For an "extremely secure" setup, prefer:

- A separate monitoring VPS (Grafana/Prometheus/Loki) that your app VPS cannot reach with admin credentials.
- Lightweight agents on the app VPS with least privilege (see `infra/monitoring-agent` and `docs/17-monitoring-separate-vps.md`).
- Full monitoring server setup guide: `docs/18-monitoring-server.md`.

## What You Get

- **System**: CPU, RAM, disk I/O, network, load
- **Docker**: Container CPU/memory, health status, logs
- **Security**: fail2ban stats, auth logs, firewall
- **Alerts**: Discord, Slack, email, PagerDuty

## Quick Setup

```bash
# 1. Create config
cd /srv/infrastructure/monitoring
cp .env.example .env
nano .env  # Set HOSTNAME

# 2. Start Netdata
sudo docker compose --compatibility up -d

# 3. Enable in Caddyfile (uncomment monitoring section)
nano /srv/infrastructure/reverse-proxy/Caddyfile

# 4. Reload Caddy
cd /srv/infrastructure/reverse-proxy && sudo docker compose restart caddy
```

Access at: `https://monitoring.yourdomain.com`

## Secure Access

**Important**: Add Cloudflare Access policy to restrict who can view monitoring.

In Cloudflare Zero Trust dashboard:
1. Access > Applications > Add
2. Self-hosted, URL: `monitoring.yourdomain.com`
3. Add policy: allow specific emails/groups

## What It Monitors

### System Metrics
- CPU usage per core
- RAM and swap usage
- Disk I/O and space
- Network traffic
- System load

### Docker
- Container CPU/memory
- Container health status
- Image sizes
- Network per container

### Security
- fail2ban banned IPs
- SSH login attempts
- UFW firewall activity

### Applications
- Web server response times
- Database connections (if configured)
- Redis/memcached stats

## Alerts

### Discord/Slack

Edit Netdata config:
```bash
sudo docker exec -it netdata bash
cd /etc/netdata
./edit-config health_alarm_notify.conf
```

Set:
```
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
# or
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

### Email

```
EMAIL_SENDER="netdata@yourdomain.com"
DEFAULT_RECIPIENT_EMAIL="you@yourdomain.com"
```

## Netdata Cloud (Optional)

Free remote access without exposing ports:

1. Create account at https://app.netdata.cloud
2. Get claim token from dashboard
3. Add to `.env`:
   ```
   NETDATA_CLAIM_TOKEN=your-token
   NETDATA_CLAIM_ROOMS=your-room-id
   ```
4. Restart: `sudo docker compose --compatibility up -d`

## Resource Usage

Netdata is lightweight:
- ~50-100MB RAM
- ~1-2% CPU
- ~100MB disk for metrics retention

## Alternatives

| Tool | Pros | Cons |
|------|------|------|
| **Netdata** | All-in-one, zero-config | Needs Cloudflare Access for security |
| Prometheus+Grafana | Very flexible | Complex setup, multiple containers |
| Datadog | Polished, APM | Expensive |
| Uptime Kuma | Simple uptime checks | No system metrics |

For single-VM setups, Netdata is the pragmatic choice.
