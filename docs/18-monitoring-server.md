# Monitoring Server (Prometheus + Grafana + Alerting)

This blueprint supports a **two-VPS monitoring architecture**:

- **App VPS**: runs apps + minimal infra (cloudflared, Caddy) + lightweight exporters
- **Monitoring VPS**: runs Prometheus/Grafana/Alertmanager and stores the credentials to scrape metrics

Goal: if the **app VPS is compromised**, monitoring should remain harder to compromise and still be able to alert you.

## Recommended Hostnames

Avoid collisions by giving each VPS its own metrics subdomains:

- `metrics.<app1>.yourdomain.com` (node-exporter)
- `docker-metrics.<app1>.yourdomain.com` (dockerd metrics)
- `cadvisor.<app1>.yourdomain.com` (per-container metrics, optional)

Example for two app VPSes:

- `metrics.app1.example.com`, `docker-metrics.app1.example.com`, `cadvisor.app1.example.com`
- `metrics.app2.example.com`, `docker-metrics.app2.example.com`, `cadvisor.app2.example.com`

If you use a wildcard tunnel DNS record (`*.yourdomain.com`), you usually don't need to create extra tunnel routes per hostname.

## App VPS: Exporters (Node + Docker + Optional cAdvisor)

### 1. Start the least-privilege monitoring agent

```bash
cd /srv/infrastructure/monitoring-agent
cp .env.example .env
sudo docker compose up -d
```

Exports:

- `node-exporter:9100` (system metrics)
- `dockerd-metrics-proxy:9324` (Docker daemon metrics, no docker.sock)

Note: the blueprint configures Docker to expose daemon metrics on `0.0.0.0:9323` (host), so the monitoring agent can proxy it without mounting `docker.sock`.
This port is **not** intended to be reachable from the public internet: UFW defaults to deny incoming traffic, and you should not open `9323` externally.
If you changed Docker daemon settings, ensure `metrics-addr` is still enabled.

### 2. Optional: enable per-container metrics (cAdvisor)

Security note: cAdvisor requires the Docker socket and host mounts (higher privilege).

```bash
cd /srv/infrastructure/monitoring-agent
sudo docker compose -f compose.yml -f compose.cadvisor.yml up -d
```

### 3. Expose scrape endpoints via Caddy

1. Attach Caddy to the `monitoring` network:

- Edit `/srv/infrastructure/reverse-proxy/compose.yml`
- Uncomment `# - monitoring` under `services.caddy.networks`

2. Enable the metrics hostnames in `/srv/infrastructure/reverse-proxy/Caddyfile`:

- `metrics.<app>.yourdomain.com` → `node-exporter:9100`
- `docker-metrics.<app>.yourdomain.com` → `dockerd-metrics-proxy:9324`
- `cadvisor.<app>.yourdomain.com` → `cadvisor:8080` (optional)

3. Restart Caddy:

```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose up -d
```

## Cloudflare Zero Trust: Lock Metrics with Service Tokens

Metrics endpoints should not be browser-auth endpoints.

In Cloudflare Zero Trust:

1. Create a service token:
   - Access → Service Auth → Service Tokens
   - Create token `prometheus-scraper`
2. Create Access applications (Self-hosted) for:
   - `metrics.app1.yourdomain.com`
   - `docker-metrics.app1.yourdomain.com`
   - `cadvisor.app1.yourdomain.com` (if enabled)
3. For each application, add a policy:
   - Action: **Service Auth**
   - Include: **Service Token** `prometheus-scraper`

This ensures:

- Prometheus gets `200` (no login redirects)
- humans cannot casually browse sensitive internal metrics

## Monitoring VPS: Prometheus + Grafana + Alerting

This repo includes a ready-to-run stack at `infra/monitoring-server/`.

### 1. Install and configure the stack

```bash
cd /srv/infrastructure/monitoring-server
cp .env.example .env
```

Create secrets (file-based, never in git):

```bash
sudo /opt/hosting-blueprint/scripts/monitoring/init-monitoring-server.sh
```

Then:

- Copy `configs/prometheus.yml.example` → `configs/prometheus.yml`
- Replace the placeholder targets with your real hostnames

Start:

```bash
sudo docker compose up -d
```

Optional:

- Put dashboard JSON files under `configs/grafana/dashboards/` to auto-provision them.

### 2. Expose Grafana via Cloudflare Tunnel + Access SSO

On the monitoring VPS, route:

- `grafana.yourdomain.com` → `http://localhost:3000`

In Cloudflare Zero Trust, protect `grafana.yourdomain.com` with an SSO policy (email domain, groups, OTP, etc.).

Notes:

- Keep Grafana's admin password enabled as defense-in-depth.
- You can optionally expose Prometheus/Alertmanager UIs the same way, but it's not required for normal operation.

## Prometheus Scraping Through Access (Service Auth)

The provided config uses custom headers:

- `CF-Access-Client-Id`
- `CF-Access-Client-Secret`

These values are mounted into the Prometheus container from:

- `/var/secrets/production/cf_access_client_id.txt`
- `/var/secrets/production/cf_access_client_secret.txt`

And are available inside the Prometheus container as:

- `/etc/prometheus/cf_access_client_id`
- `/etc/prometheus/cf_access_client_secret`

## Next Steps

- Import Grafana dashboards you like (node-exporter, Docker, cAdvisor).
- Configure Alertmanager receivers (Slack/email/webhook) in:
  - `infra/monitoring-server/configs/alertmanager.yml`
- Add more alert rules under:
  - `infra/monitoring-server/configs/alerts/`

Optional:

- Run `infra/monitoring-agent` on the monitoring VPS as well and scrape it locally (same `monitoring` Docker network).
