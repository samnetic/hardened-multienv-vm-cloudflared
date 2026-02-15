# GitOps Workflow

This guide explains how to use GitOps to manage your server. Instead of SSHing in and editing files manually, you make changes in git and deploy automatically.

## Recommended Repos (Clean UX)

For the cleanest setup, keep these concerns separate:

- **VM blueprint repo** (this repo): scripts/config/docs used to bootstrap and harden the VM.
- **Deployments repo** (recommended): contains only `.github/workflows/deploy.yml` and an `apps/` folder with your app compose files.

The workflow in `.github/workflows/deploy.yml` syncs your deployments repo to the VM (via SSH through Cloudflare Access) and triggers a guarded deploy on the VM via `hosting deploy` (the VM then runs `sudo docker compose` per app directory).

Security note (important):
- CI connects as `appmgr`, but `appmgr` is restricted via `sshd ForceCommand`.
- CI can only run `hosting sync <env>`, `hosting deploy <env> <ref>`, and `hosting status <env>`.
- The VM runs deployments via a root-owned tool (`/usr/local/sbin/hosting-deploy`) that enforces compose policy guardrails.

## What is GitOps?

**GitOps = Git + Operations**

Your git repository is the single source of truth. Changes go through git, and CI/CD deploys them automatically.

### Traditional vs GitOps

| Traditional | GitOps |
|-------------|--------|
| SSH to server | Push to git |
| Edit files manually | Edit locally, commit |
| Run commands directly | CI/CD runs commands |
| No audit trail | Full git history |
| Easy to forget changes | Everything documented |

## The Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                        Git Flow                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  feature/xyz ──push──▶ DEV (auto-deploy)                       │
│       │                                                         │
│       └──PR merge──▶ main ──▶ STAGING (auto-deploy)            │
│                        │                                        │
│                        └──tag v1.x──▶ PRODUCTION (manual)      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Environment Mapping

| Git Event | Environment | Deployment |
|-----------|-------------|------------|
| Push to `feature/*` | Dev | Automatic |
| Merge to `main` | Staging | Automatic |
| Run Deploy workflow with `version=v*` | Production | Manual + confirmation |

## Deployments Repo Layout (Expected)

Your deployments repository should look like this:

```
.
├── .github/workflows/deploy.yml
├── my-api/
│   ├── compose.yaml
│   ├── compose.staging.yaml        # optional override
│   ├── compose.production.yaml     # optional override
│   ├── .env.example                # optional (non-secret)
│   └── .env.production.enc         # optional (SOPS encrypted)
└── another-app/
    └── compose.yml
```

Notes:
- Use `compose.yaml`/`compose.yml` (base) and `compose.<env>.yaml` (override) if you want per-environment differences.
- Keep secrets on the VM under `/var/secrets` (recommended) or commit encrypted `.env.*.enc` (optional).
  - Optional: you can group app directories under an `apps/` folder; the deploy workflow supports both layouts.
  - If you use SOPS: install/configure `sops` + `age` on the VM and store your age key at `/etc/sops/age/keys.txt`.
    - Helper: `sudo /opt/hosting-blueprint/scripts/security/setup-sops-age.sh`
    - The deploy workflow can decrypt `.env.<env>.enc` to `.env.<env>` when needed.

## Step-by-Step

### 1. Fork This Repository

Click "Fork" on GitHub to create your own copy.

### 2. Clone to Your Local Machine

```bash
git clone https://github.com/YOUR-USERNAME/hardened-multienv-vm-cloudflared.git
cd hardened-multienv-vm-cloudflared
```

### 3. Initial VM Setup

```bash
# SSH to your fresh VM
ssh root@your-server-ip

# Clone your fork
git clone https://github.com/YOUR-USERNAME/hardened-multienv-vm-cloudflared.git
cd hardened-multienv-vm-cloudflared

# Run setup
sudo ./setup.sh
```

### 4. Configure GitHub Secrets

Go to your repo: **Settings > Secrets and variables > Actions**

Add these secrets:

| Secret | Value |
|--------|-------|
| `SSH_PRIVATE_KEY` | Your Ed25519 private key for appmgr user |
| `SSH_HOST` | `ssh.yourdomain.com` |
| `SSH_USER` | `appmgr` |
| `SSH_KNOWN_HOSTS` | Pinned host key(s) for `SSH_HOST` (prevents MITM) |
| `CF_SERVICE_TOKEN_ID` | Cloudflare Access service token ID |
| `CF_SERVICE_TOKEN_SECRET` | Cloudflare Access service token secret |

### Generate `SSH_KNOWN_HOSTS` (Recommended)

On the server, print a `known_hosts` entry using the server's own host keys:

```bash
./scripts/ssh/print-known-hosts.sh ssh.yourdomain.com
```

Copy the output into the GitHub Actions secret `SSH_KNOWN_HOSTS`.

### 5. Create GitHub Environments

Go to: **Settings > Environments**

Create three environments:
- `dev` - No protection rules
- `staging` - Optional: require status checks to pass
- `production` - Required: add reviewers for manual approval

### 6. Start Making Changes

```bash
# Create a feature branch
git checkout -b feature/add-my-app

# Make your changes
cp -r apps/_template apps/myapp
# Edit files...

# Commit and push
git add .
git commit -m "Add myapp"
git push -u origin feature/add-my-app
```

This automatically deploys to **DEV**.

### 7. Test in Dev

Visit `https://dev-myapp.yourdomain.com` to test your changes.

### 8. Create Pull Request

On GitHub, create a PR from `feature/add-my-app` to `main`.

### 9. Merge to Staging

After review, merge the PR. This automatically deploys to **STAGING**.

### 10. Deploy to Production

When ready for production:

1. Go to **Actions** tab
2. Select **Deploy** workflow
3. Click **Run workflow**
4. Select `production` environment
5. Enter the version tag (e.g., `v1.0.0`)
6. Type `DEPLOY` to confirm
7. Approve the deployment (if reviewers required)

## Making Changes

### Modify Caddyfile

```bash
git checkout -b feature/update-caddyfile
# Edit reverse-proxy/Caddyfile (in your /srv/infrastructure repo)
git add .
git commit -m "Update Caddy routing for new app"
git push
```

### Add New Application

```bash
git checkout -b feature/new-app
cp -r apps/_template apps/myapp
# Configure compose.yml and .env
git add .
git commit -m "Add myapp"
git push
```

### Update Hardening Config

```bash
git checkout -b feature/harden-ssh
# Edit config/ssh/sshd_config.d/hardening.conf
git add .
git commit -m "Strengthen SSH cipher configuration"
git push
```

## Emergency Changes

If something is broken and you need to fix it immediately:

### Option 1: Hotfix Branch (Preferred)

```bash
git checkout main
git checkout -b hotfix/fix-critical-bug
# Make fix
git add .
git commit -m "Fix critical bug"
git push
# Create PR, merge to main → auto-deploys to staging
# Then manually deploy to production
```

### Option 2: Direct SSH (Last Resort)

```bash
# SSH to server
# Recommended: use the short alias created by scripts/setup-local-ssh.sh
ssh yourdomain

# Make emergency fix
sudo nano /etc/whatever

# IMPORTANT: Mirror the change back to git ASAP (server changes are not the source of truth).
```

## Rollback

### Rollback Strategy (Recommended)

- **Dev/Staging:** revert and push (triggers auto-deploy), or deploy a rollback commit.
- **Production:** run the manual deploy workflow with a previous tag (e.g. deploy `v1.2.3` again).

## Best Practices

### DO

- Always work in feature branches
- Write descriptive commit messages
- Test in dev before merging to staging
- Tag releases with semantic versions (v1.0.0, v1.1.0)
- Keep secrets out of git (store in /var/secrets)

### CI User Model (How It Stays Safe)

On the VM:
- `appmgr` has no interactive shell access (ForceCommand wrapper).
- `appmgr` is not in the docker group.
- Deploys happen via `hosting-deploy` (root) with policy checks.

Policy guardrails (default):
- Deny `ports:` publishing (tunnel-only)
- Deny privileged containers, host namespaces, devices, docker.sock mounts
- Deny bind mounts outside the app directory (except allowlisted prefixes like `/var/secrets`, `/srv/static`)
- Deny `build:` directives (prefer CI-built images; override via `ALLOW_BUILD=1` if you accept the risk)

To test the CI interface manually:

```bash
# On your local machine (after running scripts/setup-local-ssh.sh):
ssh yourdomain-appmgr "hosting status dev"
```

### DON'T

- Push directly to main (use PRs)
- Deploy to production without testing in staging
- Make changes directly on the server (except emergencies)
- Store secrets in git

## Monitoring Deployments

### GitHub Actions

Watch deployment progress in **Actions** tab.

### Server Status

```bash
# Check deployment
./scripts/monitoring/status.sh

# Check container logs
./scripts/monitoring/logs.sh docker

# Check specific app
cd /srv/apps/staging/myapp
sudo docker compose logs -f
```

## Troubleshooting

### Deployment Failed

1. Check GitHub Actions logs for error
2. Check status via the restricted CI interface (optional):
   ```bash
   ssh yourdomain-appmgr "hosting status staging"
   ```
3. SSH to server as sysadmin and check container status:
   ```bash
   ssh -T yourdomain
   ls -la /srv/apps/staging
   cd /srv/apps/staging/<app-name>
   sudo docker compose ps
   sudo docker compose logs --tail=200
   ```

### SSH Connection Failed

- Verify GitHub secrets are correct
- Check Cloudflare Access service token is valid
- Verify appmgr user exists and has SSH key

### Changes Not Visible

- Wait for deployment to complete
- Check correct environment (dev/staging/production)
- Hard refresh browser (Ctrl+Shift+R)
- Check container is running: `sudo docker compose ps`
