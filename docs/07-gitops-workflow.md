# GitOps Workflow

This guide explains how to use GitOps to manage your server. Instead of SSHing in and editing files manually, you make changes in git and deploy automatically.

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
| Create tag `v*` | Production | Manual approval |

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
| `CF_SERVICE_TOKEN_ID` | Cloudflare Access service token ID |
| `CF_SERVICE_TOKEN_SECRET` | Cloudflare Access service token secret |

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
# Edit infra/reverse-proxy/Caddyfile
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
ssh sysadmin@ssh.yourdomain.com

# Make emergency fix
sudo nano /etc/whatever

# IMPORTANT: Commit the change back to git!
cd /srv/apps/production
git diff  # See what changed
# Then make the same change in git on your local machine
```

## Rollback

### Staging Rollback

```bash
# SSH to server
ssh appmgr@ssh.yourdomain.com

cd /srv/apps/staging
git log --oneline -5  # Find commit to rollback to
git reset --hard abc123
docker compose up -d
```

### Production Rollback

Use the manual deploy workflow with a previous tag version.

## Best Practices

### DO

- Always work in feature branches
- Write descriptive commit messages
- Test in dev before merging to staging
- Tag releases with semantic versions (v1.0.0, v1.1.0)
- Keep secrets out of git (use the secrets/ directory)

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
docker compose -f apps/myapp/compose.yml logs -f
```

## Troubleshooting

### Deployment Failed

1. Check GitHub Actions logs for error
2. SSH to server and check container status:
   ```bash
   ssh appmgr@ssh.yourdomain.com
   cd /srv/apps/staging
   docker compose ps
   docker compose logs
   ```

### SSH Connection Failed

- Verify GitHub secrets are correct
- Check Cloudflare Access service token is valid
- Verify appmgr user exists and has SSH key

### Changes Not Visible

- Wait for deployment to complete
- Check correct environment (dev/staging/production)
- Hard refresh browser (Ctrl+Shift+R)
- Check container is running: `docker compose ps`
