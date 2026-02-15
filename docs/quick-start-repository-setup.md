# Quick Start: Repository Layout (Recommended)

This blueprint works best when you separate:

- **Template repo** (this repo) from
- **Infrastructure repo** (reverse proxy, monitoring) and
- **Deployments repo** (your app compose files per environment)

This keeps UX clean and avoids accidentally committing secrets.

## Server Layout

```
/opt/hosting-blueprint/            # This template repo (bootstrap installs here)
/srv/infrastructure/               # Your infra repo (git tracked)
/srv/apps/
  dev/                             # Your DEV deployments repo checkout
  staging/                         # Your STAGING deployments repo checkout
  production/                      # Your PRODUCTION deployments repo checkout
/var/secrets/{dev,staging,production}/   # Secrets (never in git)
```

## Step 1: Initialize `/srv/infrastructure`

On the VM:

```bash
sudo /opt/hosting-blueprint/scripts/setup-infrastructure-repo.sh yourdomain.com
```

This:

- Creates `/srv/infrastructure`
- Copies templates (`reverse-proxy/`, `monitoring/`, `cloudflared/`)
- Configures the domain in `reverse-proxy/Caddyfile`
- Starts Caddy (localhost-bound)

## Step 2: Create a Deployments Repo

Create a private Git repo (example: `mycompany-vps-deployments`) with structure like:

```
api/
  compose.yml
n8n/
  compose.yml
```

Copy `.github/workflows/deploy.yml` into that repo. Then GitHub Actions deploys it to the VM at:

- `/srv/apps/dev`
- `/srv/apps/staging`
- `/srv/apps/production`

The workflow syncs the deployments repo to the VM (via SSH through Cloudflare Access) and triggers `hosting sync` + `hosting deploy` (compose deploy with policy checks).

## Step 3: Pin SSH Host Keys for CI (Required)

On the VM, generate `known_hosts` entries:

```bash
./scripts/ssh/print-known-hosts.sh ssh.yourdomain.com
```

Add the output to your GitHub Actions secret `SSH_KNOWN_HOSTS`.

## Step 4: Keep Secrets Out of Git

Use file-based secrets under `/var/secrets`:

```bash
./scripts/secrets/create-secret.sh production db_password
```

In your app `compose.yml`, mount secrets to `/run/secrets/*` and point your app to `*_FILE` env vars.

## Optional: Encrypted `.env` in Git (SOPS/age)

If you prefer committing encrypted env files (industry standard), keep:

- plaintext `.env` files **gitignored**
- encrypted `.env.*.enc` files **tracked**

This repo’s `.gitignore` allows `!.env.*.enc` so you can adopt that pattern later.

If you use SOPS on the VM:
- Install `sops` on the VM.
- Store your age key at `/etc/sops/age/keys.txt` (or set `SOPS_AGE_KEY_FILE`).
- The deploy workflow can decrypt `.env.<env>.enc` into `.env.<env>` when needed.
