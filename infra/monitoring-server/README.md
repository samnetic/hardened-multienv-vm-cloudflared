# Monitoring Server (Separate VPS)

This stack is intended to run on a **separate monitoring VPS** and scrape metrics from your app VPS(es) through **Cloudflare Tunnel + Cloudflare Access Service Tokens**.

What you get:

- Prometheus (scrapes `node-exporter`, Docker daemon metrics, optional cAdvisor)
- Grafana (dashboards)
- Alertmanager (routing/notifications)

This repo also includes a **least-privilege monitoring agent** for each app VPS at `infra/monitoring-agent/`.

## Quick Start (Monitoring VPS)

1. Copy env:

```bash
cd /srv/infrastructure/monitoring-server
cp .env.example .env
```

2. Create required secrets (file-based, never in git):

```bash
# One command: prevents missing-file bind-mount footguns and creates required secrets.
# - Generates Grafana admin password if missing
# - Prompts for Cloudflare Access service token values used by Prometheus to scrape protected /metrics endpoints
sudo /opt/hosting-blueprint/scripts/monitoring/init-monitoring-server.sh
```

3. Configure Prometheus scrape targets:

- Copy and edit `configs/prometheus.yml.example` → `configs/prometheus.yml`
- Add your `metrics.*`, `docker-metrics.*`, and optional `cadvisor.*` hostnames.

4. Start:

```bash
sudo docker compose up -d
```

5. Expose Grafana via Cloudflare Tunnel:

- In your monitoring VPS `cloudflared` config, map `grafana.yourdomain.com` → `http://localhost:3000`
- Protect `grafana.yourdomain.com` with Cloudflare Access (SSO)

End-to-end guide: see `docs/18-monitoring-server.md`.

## Optional

- Auto-provision dashboards: put JSON files under `configs/grafana/dashboards/`
- Configure notifications: edit `configs/alertmanager.yml`
