# Infrastructure Template Structure

This blueprint keeps the **template repo** (`/opt/hosting-blueprint`, root-owned) separate from the **runtime infrastructure** (`/srv/infrastructure`, sysadmin-owned).

Goal:

- `/opt/hosting-blueprint` stays clean and safely updatable (`git pull` as root).
- `/srv/infrastructure` is where you actually run and GitOps your reverse proxy and monitoring.

## Runtime Layout (`/srv/infrastructure`)

After setup, `/srv/infrastructure` contains the copied templates (no credentials):

```
/srv/infrastructure/
  reverse-proxy/
    compose.yml
    Caddyfile
    .env.example
    compose.override.yml.example

  cloudflared/
    config.yml.example
    tunnel-setup.md

  monitoring-agent/
    compose.yml
    compose.cadvisor.yml
    .env.example
    README.md

  monitoring/
    compose.yml
    .env.example

  monitoring-server/
    compose.yml
    .env.example
    configs/
      prometheus.yml.example
      alertmanager.yml
      grafana/
        provisioning/
        dashboards/
    secrets/
```

Notes:

- **No tunnel credentials** in `/srv/infrastructure`. The active cloudflared creds live under `/etc/cloudflared/`.
- **No app secrets** in `/srv/infrastructure`. Use `/var/secrets/{dev,staging,production}`.

## How `/srv/infrastructure` Is Created

Option 1 (recommended):

```bash
sudo /opt/hosting-blueprint/scripts/setup-infrastructure-repo.sh yourdomain.com
```

Option 2 (already done by `setup.sh` on first run):

- `setup.sh` will initialize `/srv/infrastructure` from `/opt/hosting-blueprint/infra/` when needed.

## Reverse Proxy (`/srv/infrastructure/reverse-proxy`)

This is Caddy (HTTP-only) behind Cloudflare Tunnel.

Start / restart:

```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose --compatibility up -d
sudo docker compose logs -f caddy
```

Add a new hostname:

1. Edit `/srv/infrastructure/reverse-proxy/Caddyfile`
2. Keep `import tunnel_only` in every site block.
3. Apply safely:

```bash
sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
```

## Cloudflared (`/etc/cloudflared` is the real config)

The `cloudflared/` folder under `/srv/infrastructure` is a **reference template** only.

Active runtime files:

- `/etc/cloudflared/config.yml`
- `/etc/cloudflared/<tunnel-uuid>.json` (credentials)

Use:

- `scripts/setup-cloudflared.sh` for guided setup
- `scripts/finalize-tunnel.sh` to flip to tunnel-only mode (blocks inbound 22/80/443)

## Monitoring (Two Modes)

### Mode A: Separate Monitoring VPS (recommended)

- App VPS runs: `monitoring-agent/` (exporters only, no UI)
- Monitoring VPS runs: `monitoring-server/` (Prometheus + Grafana + Alerting)

See:

- `docs/17-monitoring-separate-vps.md`
- `docs/18-monitoring-server.md`

### Mode B: Local Netdata (convenience, higher privilege)

```bash
cd /srv/infrastructure/monitoring
cp .env.example .env
sudo docker compose --compatibility up -d
```

Security note: Netdata often needs `docker.sock` and extra host visibility. If you want the tightest blast radius, prefer the separate monitoring VPS model.

