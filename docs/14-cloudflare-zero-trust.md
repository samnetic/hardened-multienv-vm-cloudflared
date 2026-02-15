# Cloudflare Zero Trust (Access)

Use Cloudflare Access to protect services at the edge:

- Humans: SSO/OTP (admin UIs)
- Machines: service tokens (Prometheus, CI/CD, webhook senders that support headers)

Traffic model:

```
Client -> Cloudflare (Access policy) -> Cloudflare Tunnel -> Your origin (Caddy/app)
```

## Quick Setup (Checklist)

1. Enable Zero Trust
   - Cloudflare dashboard -> Zero Trust
   - Create a team name (becomes `<team>.cloudflareaccess.com`)
2. Add login methods
   - Settings -> Authentication -> Login methods
   - Add One-time PIN (OTP) for emergency access
   - Add Google/GitHub (optional) for daily use
3. Decide per-hostname policy type
   - Admin UIs: `Allow` (SSO/OTP)
   - Machine endpoints: `Service Auth` (service tokens)
   - Public endpoints: no Access app (validate at app layer)

## Policy Patterns (Use These)

### Pattern A: Admin UIs (Humans) -> `Allow`

Use for:

- Grafana
- Netdata
- n8n editor
- any admin panel

Steps:

1. Access -> Applications -> Add an application -> Self-hosted
2. Application domain: `grafana.yourdomain.com` (example)
3. Policy:
   - Action: Allow
   - Include: emails/groups/IdP rules

Example "Allow" policy:

- Include:
  - Emails ending in: `@yourcompany.com`
- (Optional) Also include:
  - Login Methods: One-time PIN (for break-glass access)

Recommendation:

- Keep the app's own login enabled as defense-in-depth (e.g., Grafana admin password), even if Access SSO is in front.

### Pattern B: Machine Endpoints -> `Service Auth`

Use for:

- `/metrics` endpoints (Prometheus scraping)
- CI/CD endpoints
- webhook senders that can set custom headers

Steps:

1. Access -> Service Auth -> Service Tokens -> Create Service Token
   - Example name: `prometheus-scraper`
   - Copy Client ID + Client Secret (shown once)
2. Access -> Applications -> Add -> Self-hosted
   - Example hostname: `metrics-app1.yourdomain.com`
3. Policy:
   - Action: Service Auth
   - Include: Service Token `prometheus-scraper`

Clients must send:

- `CF-Access-Client-Id: <id>`
- `CF-Access-Client-Secret: <secret>`

### Pattern C: Webhooks You Cannot Protect with Access

Some third-party senders cannot set Access headers.

Preferred options:

1. Dedicated public hostname (no Access app) + strong app-level validation (signature/HMAC/token)
2. If the provider has stable IP ranges: Access bypass by IP (still validate at app level)

## Monitoring (Recommended)

Recommended split:

- App VPS: exporters + metrics endpoints (protected by Service Auth)
- Monitoring VPS: Prometheus/Grafana/Alertmanager (Grafana protected by Allow/SSO)

Docs:

- `docs/17-monitoring-separate-vps.md`
- `docs/18-monitoring-server.md`

## SSH: Humans vs CI

Protect `ssh.yourdomain.com` with Access policies:

- humans: Allow (SSO/OTP)
- CI: Service Auth (service token)

This lets you keep a single SSH tunnel hostname while still separating trust levels.

## JWT Validation (Advanced: Custom Apps)

Cloudflare Access can inject a signed JWT in the `Cf-Access-Jwt-Assertion` header.
Validate it in your app if you want app-level authorization (defense-in-depth).

This repo includes reference validators:

- `scripts/cloudflare-access/validate-jwt.py`
- `scripts/cloudflare-access/validate-jwt.js`

Required env vars:

| Variable | Description | Example |
|----------|-------------|---------|
| `CF_TEAM_DOMAIN` | Your team domain | `mycompany.cloudflareaccess.com` |
| `CF_AUD_TAG` | App audience (AUD) tag | `a1b2c3d4e5...` |

Quick test:

```bash
CF_TEAM_DOMAIN=mycompany.cloudflareaccess.com \
CF_AUD_TAG=your-aud-tag \
python scripts/cloudflare-access/validate-jwt.py
```

## Tunnel Config Notes

This blueprint typically routes all HTTP traffic to Caddy:

- Tunnel ingress: `service: http://localhost:80`
- Caddy routes by hostname to containers on internal Docker networks
- Access policies are enforced per-hostname in Zero Trust

See: `infra/cloudflared/config.yml.example`

## Troubleshooting (Common Gotchas)

- Prometheus gets redirected to a login page:
  - metrics hostnames must be `Service Auth` (not `Allow`)
- "Access denied" after login:
  - application hostname must match exactly
  - policy must include your email/group/service token
- Webhook endpoints show a login screen:
  - remove Access app for that hostname, or use Service Auth if possible
