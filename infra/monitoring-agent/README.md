# Monitoring Agent (App VPS)

This folder contains a security-first monitoring agent you can run on each **app VPS**.

Default goals:

- Export system metrics (node-exporter)
- Export Docker daemon metrics (dockerd metrics) without mounting `docker.sock`
- No published ports (expose via Caddy + Cloudflare Access if needed)

## Quick Start

```bash
cd /srv/infrastructure/monitoring-agent
cp .env.example .env
sudo docker compose up -d
```

## Optional: Per-Container Metrics (cAdvisor)

If you need per-container CPU/memory/filesystem metrics, enable the optional override:

```bash
sudo docker compose -f compose.yml -f compose.cadvisor.yml up -d
```

Security note:

- `docker.sock` access is effectively root on the host.
- Always protect the cAdvisor hostname with Cloudflare Access Service Auth.

Guide:

- `docs/17-monitoring-separate-vps.md`
- `docs/18-monitoring-server.md`

