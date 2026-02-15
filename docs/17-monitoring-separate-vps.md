# Separate Monitoring VPS (Recommended)

For an “extremely secure” setup, treat monitoring as a **separate control plane**:

- Your **app VPS** should run only your apps + the minimum local infra (cloudflared, Caddy).
- Your **monitoring VPS** should run dashboards/alerting and hold the credentials to query metrics.
- If the app VPS is compromised, it should not automatically compromise monitoring.

This repo includes a **least-privilege monitoring agent** for the app VPS and a clean pattern to protect scrape endpoints with **Cloudflare Access Service Tokens**.

For the full end-to-end setup (Prometheus + Grafana + alerting on a monitoring VPS), see:

- `docs/18-monitoring-server.md`

## App VPS: Run The Monitoring Agent

1. Start the agent:

```bash
cd /srv/infrastructure/monitoring-agent
cp .env.example .env
sudo docker compose --compatibility up -d
```

Note: the blueprint configures Docker to expose daemon metrics on `0.0.0.0:9323` (host), so the monitoring agent can proxy it without mounting `docker.sock`.
This port is **not** intended to be reachable from the public internet: UFW defaults to deny incoming traffic, and you should not open `9323` externally.
If you changed Docker daemon settings, ensure `metrics-addr` is still enabled.

Optional: enable per-container metrics (cAdvisor):

```bash
cd /srv/infrastructure/monitoring-agent
sudo docker compose --compatibility -f compose.yml -f compose.cadvisor.yml up -d
```

2. Expose scrape endpoints via Caddy:

- Caddy is already attached to the `monitoring` network by default in this blueprint.
  If you customized `/srv/infrastructure/reverse-proxy/compose.yml`, ensure `monitoring` is listed under `services.caddy.networks`.

- Add hostnames to `/srv/infrastructure/reverse-proxy/Caddyfile` (templates are already present):
  - `metrics.<domain>` → `node-exporter:9100`
  - `docker-metrics.<domain>` → `dockerd-metrics-proxy:9324`
  - `cadvisor.<domain>` → `cadvisor:8080` (optional)

3. Restart Caddy:

```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose --compatibility up -d
```

## Cloudflare Zero Trust: Protect Metrics With Service Tokens

In Cloudflare Zero Trust:

1. Access → Applications → Add → Self-hosted:
   - `metrics.<domain>`
   - `docker-metrics.<domain>`
   - `cadvisor.<domain>` (optional)
2. For each app, create a policy:
   - Action: **Service Auth**
   - Include: your service token (e.g. `prometheus-scraper`)

This prevents browser redirects and gives clean machine-to-machine auth.

## Monitoring VPS: Prometheus Scrape Config (Service Token Headers)

Prometheus can send custom headers in `http_headers`.

Example:

```yaml
scrape_configs:
  - job_name: node
    scheme: https
    metrics_path: /metrics
    static_configs:
      - targets:
          - metrics-app1.example.com
          - metrics-app2.example.com
    http_headers:
      CF-Access-Client-Id:
        files:
          - /etc/prometheus/cf_access_client_id
      CF-Access-Client-Secret:
        files:
          - /etc/prometheus/cf_access_client_secret
```

Operational guidance:
- Keep the token values in root-owned files on the monitoring VPS.
- Rotate tokens periodically (treat them like API keys).
- Protect Grafana/Alertmanager UIs with Cloudflare Access SSO.

## Netdata Note

`infra/monitoring/compose.yml` (Netdata) is convenient, but requires elevated visibility (e.g. Docker socket, extra caps) for “deep” monitoring.

If you want a tighter blast radius:
- Prefer the `infra/monitoring-agent` + separate monitoring VPS pattern.
- Keep Netdata as an optional convenience tool, behind Cloudflare Access.
