# Simple API Example (Node.js / Express)

This is a small Express API example wired for the blueprint’s **tunnel-only** and **GitOps-friendly** model.

## What This Example Demonstrates

- Pre-built image deploy (preferred): no `build:`, no host `ports:`
- Hardened container defaults: `no-new-privileges`, `cap_drop: [ALL]`, `read_only`, `tmpfs`
- Works behind Caddy on the shared environment network (`staging-web` / `prod-web`)

## Deploy (Staging/Production)

```bash
# Copy example to your apps folder
sudo mkdir -p /srv/apps/staging
sudo cp -r apps/examples/simple-api /srv/apps/staging/simple-api
cd /srv/apps/staging/simple-api

# Configure (use a pinned image)
cp .env.example .env
nano .env

# Pull + start
sudo docker compose pull
sudo docker compose up -d

# Logs / health
sudo docker compose logs -f
sudo docker compose exec app node -e "require('http').get('http://localhost:3000/health', r => { process.exit(r.statusCode===200?0:1) })"
```

## Local/VM-Side Build (Convenience Only)

This is intentionally separated so CI/GitOps stays strict.

```bash
sudo docker compose -f compose.yml -f compose.local.yml up -d --build
curl -fsS http://127.0.0.1:3000/health
```

## Add a Hostname in Caddy

Edit `/srv/infrastructure/reverse-proxy/Caddyfile`:

```caddyfile
http://staging-api.yourdomain.com {
  import tunnel_only
  import security_headers
  reverse_proxy app-staging:3000 {
    import proxy_headers
  }
}
```

Restart Caddy:

```bash
cd /srv/infrastructure/reverse-proxy
sudo docker compose restart caddy
```

## Cloudflare Access (Recommended)

Protect admin/API hostnames at the edge:
- Add a **Self-hosted** Access app for `staging-api.yourdomain.com`
- Use **SSO** for humans, **Service Tokens** for machine callers (webhooks/CI)

See `docs/14-cloudflare-zero-trust.md`.

