# Environment Tiers

This guide explains the three environments and when to use each.

## Overview

| Environment | Purpose | Stability | Access |
|-------------|---------|-----------|--------|
| **Dev** | Playground, experimentation | Can break | Developers |
| **Staging** | Pre-production testing | Should be stable | Team |
| **Production** | Live users | Must be stable | Everyone |

## Dev Environment

### Purpose

- Test new features before committing
- Debug issues in isolation
- Connect local tools to remote databases
- Experiment without fear of breaking things

### Characteristics

```
Subdomain:    dev-*.yourdomain.com
Networks:     dev-web (bridge), dev-backend (bridge - NOT internal!)
Deployment:   Auto on push to feature/* branches
Protection:   None
```

### Why Dev Backend is NOT Internal

The dev-backend network is intentionally **not** internal, allowing you to:

```bash
# Connect from your local machine to dev database
psql -h dev-db.yourdomain.com -U myuser -d mydb

# Use local IDE with remote dev database
# Great for debugging with real-ish data
```

### Use Cases

- "Let me try this risky refactoring"
- "I need to test with a real database"
- "Can we see how this looks deployed?"
- "Debug this weird issue that only happens in Linux"

## Staging Environment

### Purpose

- Final testing before production
- Verify deployments work correctly
- QA and acceptance testing
- Demo to stakeholders

### Characteristics

```
Subdomain:    staging-*.yourdomain.com
Networks:     staging-web (bridge), staging-backend (internal)
Deployment:   Auto on merge to main branch
Protection:   Optional CI checks required
```

### Why Staging Backend IS Internal

Staging should mirror production security:

```bash
# This will NOT work (by design)
psql -h staging-db.yourdomain.com -U myuser -d mydb
# Connection refused - database not exposed

# Database only accessible from staging containers
docker exec staging-app psql -h staging-db -U myuser -d mydb
# This works - container-to-container on internal network
```

### Use Cases

- "Can you verify this feature before we ship?"
- "Let's demo to the client"
- "Run the full test suite against deployed code"
- "Is this production-ready?"

## Production Environment

### Purpose

- Serve real users
- Handle real traffic
- Process real data
- Generate real revenue

### Characteristics

```
Subdomain:    *.yourdomain.com (no prefix)
Networks:     prod-web (bridge), prod-backend (internal)
Deployment:   Manual with approval (git tags)
Protection:   Requires manual approval + reviewers
```

### Why Production Has Manual Deployment

Automatic deployments to production are risky:

- A bug in main could take down your site
- You want to control exactly when updates go out
- Some changes need database migrations first
- You might want to deploy outside business hours

### Use Cases

- "Ship it!"
- "Our users need this fix"
- "Time to release v2.0"

## Network Isolation

```
┌─────────────────────────────────────────────────────────────┐
│                        DEV                                  │
│  ┌─────────────┐     ┌─────────────┐                       │
│  │  dev-web    │────▶│ dev-backend │──── Accessible from   │
│  │  (bridge)   │     │  (bridge)   │     local machine!    │
│  └─────────────┘     └─────────────┘                       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                      STAGING                                │
│  ┌─────────────┐     ┌─────────────┐                       │
│  │staging-web  │────▶│staging-back │──── Internal only     │
│  │  (bridge)   │     │ (internal)  │     (no external)     │
│  └─────────────┘     └─────────────┘                       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     PRODUCTION                              │
│  ┌─────────────┐     ┌─────────────┐                       │
│  │  prod-web   │────▶│ prod-backend│──── Internal only     │
│  │  (bridge)   │     │ (internal)  │     (most secure)     │
│  └─────────────┘     └─────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

## Secrets Per Environment

Each environment has its own secrets:

```
secrets/
├── dev/
│   ├── db_password.txt      # Can be simple for dev
│   └── api_key.txt          # Test API keys
├── staging/
│   ├── db_password.txt      # Stronger, but not production
│   └── api_key.txt          # Staging API keys
└── production/
    ├── db_password.txt      # Strong, unique, rotated regularly
    └── api_key.txt          # Production API keys
```

**Never share secrets between environments!**

## Deployment Flow

```
Developer workstation
        │
        │ git push feature/xyz
        ▼
┌───────────────┐
│     DEV       │◀─── Automatic deploy
│  (testing)    │     on feature/* push
└───────────────┘
        │
        │ PR merge to main
        ▼
┌───────────────┐
│   STAGING     │◀─── Automatic deploy
│    (QA)       │     on main merge
└───────────────┘
        │
        │ Manual approval + tag
        ▼
┌───────────────┐
│  PRODUCTION   │◀─── Manual deploy
│   (live)      │     requires approval
└───────────────┘
```

## Typical Workflow

### Day 1: Start Feature

```bash
git checkout -b feature/user-avatars
# Write code
git push
# → Auto-deploys to dev
# Test at dev-app.example.com
```

### Day 2: Feature Complete

```bash
# Create PR to main
# Review, approve
# Merge
# → Auto-deploys to staging
# Test at staging-app.example.com
# QA approves
```

### Day 3: Release

```bash
git tag v1.5.0
git push --tags
# Go to GitHub Actions
# Manually trigger production deploy
# Approve in review
# → Deploys to production
# Verify at app.example.com
```

## Environment-Specific Configuration

### In compose.yml

```yaml
services:
  app:
    environment:
      - NODE_ENV=${NODE_ENV}  # development/staging/production
      - LOG_LEVEL=${LOG_LEVEL}  # debug/info/warn
    networks:
      - ${DOCKER_NETWORK}  # dev-web/staging-web/prod-web
```

### In .env (per environment)

**apps/myapp/.env.dev:**
```
ENVIRONMENT=dev
NODE_ENV=development
LOG_LEVEL=debug
DOCKER_NETWORK=dev-web
```

**apps/myapp/.env.staging:**
```
ENVIRONMENT=staging
NODE_ENV=staging
LOG_LEVEL=info
DOCKER_NETWORK=staging-web
```

**apps/myapp/.env.production:**
```
ENVIRONMENT=production
NODE_ENV=production
LOG_LEVEL=warn
DOCKER_NETWORK=prod-web
```

## FAQ

### Can I skip staging?

Not recommended. Staging catches issues before they affect users. Even small changes should go through staging.

### Can I deploy directly to production?

Yes, in emergencies. But document why and create a proper PR afterward.

### How do I test production configs locally?

Use staging - it should mirror production security. Don't try to replicate production locally.

### What if staging and production need different configs?

That's normal. Use environment-specific `.env` files and secrets. The code should be the same, only configuration differs.
