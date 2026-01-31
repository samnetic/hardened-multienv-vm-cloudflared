# Secrets Management

This guide explains how secrets work in this template and best practices for managing them.

## Overview

We use **file-based secrets** instead of environment variables. This provides the same security as Docker Swarm secrets without requiring Swarm mode.

## Why File-Based Secrets?

| Method | Problem |
|--------|---------|
| `.env` files | Easily committed to git by accident |
| Environment variables | Visible in `docker inspect`, process listings, logs |
| Docker Swarm secrets | Requires Swarm mode (deprecated/complex) |
| **File-based secrets** | Secure, simple, works with plain Compose |

### Security Benefits

1. **Not in docker inspect** - `docker inspect container` won't show secrets
2. **Not in process listings** - `ps aux` won't expose them
3. **Permissions enforced** - Files are `chmod 600` (owner only)
4. **Read-only mount** - Containers can't modify secrets
5. **Gitignored** - Can't accidentally commit

## How It Works

### 1. Create Secret File

```bash
./scripts/secrets/create-secret.sh staging db_password
# Enter secret value: (hidden)
# Confirm: (hidden)
# ✓ Secret created: staging/db_password
```

This creates: `secrets/staging/db_password.txt` with `chmod 600`

### 2. Mount in compose.yml

```yaml
services:
  app:
    volumes:
      # Mount secret file to /run/secrets/ (read-only)
      - ../../secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
    environment:
      # Tell app where to find the secret
      - DATABASE_PASSWORD_FILE=/run/secrets/db_password
```

### 3. Read in Application

**Node.js:**
```javascript
const fs = require('fs');

function getSecret(name) {
  const envVar = `${name}_FILE`;
  const filePath = process.env[envVar];

  if (filePath && fs.existsSync(filePath)) {
    return fs.readFileSync(filePath, 'utf8').trim();
  }

  // Fallback to direct env var (local dev)
  return process.env[name];
}

const dbPassword = getSecret('DATABASE_PASSWORD');
```

**Python:**
```python
import os
from pathlib import Path

def get_secret(name: str) -> str:
    file_path = os.environ.get(f'{name}_FILE')

    if file_path and Path(file_path).exists():
        return Path(file_path).read_text().strip()

    # Fallback to direct env var
    return os.environ.get(name)

db_password = get_secret('DATABASE_PASSWORD')
```

**Go:**
```go
func getSecret(name string) string {
    filePath := os.Getenv(name + "_FILE")

    if filePath != "" {
        if data, err := os.ReadFile(filePath); err == nil {
            return strings.TrimSpace(string(data))
        }
    }

    return os.Getenv(name)
}
```

## Secret Management Commands

### Create a Secret

```bash
# Interactive (recommended for passwords)
./scripts/secrets/create-secret.sh <env> <name>

# Generate random secret
./scripts/secrets/create-secret.sh <env> <name> --generate 32

# Pipe from stdin
echo "my-secret-value" | ./scripts/secrets/create-secret.sh <env> <name>

# From password manager (1Password example)
op read "op://Vault/Item/password" | ./scripts/secrets/create-secret.sh prod db_password
```

### List Secrets

```bash
./scripts/secrets/list-secrets.sh          # All environments
./scripts/secrets/list-secrets.sh dev      # Dev only
./scripts/secrets/list-secrets.sh staging  # Staging only
```

### Rotate a Secret

```bash
./scripts/secrets/rotate-secret.sh staging db_password
# Creates backup: secrets/staging/.backups/db_password.20240115120000.txt
# Prompts for new value
```

After rotating, redeploy affected containers:
```bash
docker compose -f apps/myapp/compose.yml up -d
```

## Directory Structure

```
secrets/
├── .gitignore              # Ignores *.txt files
├── README.md               # Documentation
├── dev/
│   ├── .gitkeep
│   ├── db_password.txt     # Dev database password
│   └── api_key.txt         # Dev API key
├── staging/
│   ├── .gitkeep
│   ├── db_password.txt
│   └── api_key.txt
└── production/
    ├── .gitkeep
    ├── db_password.txt
    └── api_key.txt
```

## Common Secrets

| Secret | Purpose | Example |
|--------|---------|---------|
| `db_password` | Database authentication | PostgreSQL, MySQL |
| `api_key` | External API authentication | Stripe, SendGrid |
| `jwt_secret` | Token signing | Auth tokens |
| `smtp_password` | Email sending | Transactional emails |
| `encryption_key` | Data encryption | At-rest encryption |

## Best Practices

### DO

- Use the provided scripts to create secrets
- Rotate secrets regularly (quarterly minimum)
- Use different secrets per environment
- Back up secrets securely (encrypted)
- Use strong, random values for auto-generated secrets

### DON'T

- Commit secrets to git (they're gitignored, but be careful)
- Share production secrets via Slack/email
- Use the same secret across environments
- Store secrets in environment variables directly
- Log secret values

## Backing Up Secrets

Secrets should be backed up securely. Options:

### Option 1: Password Manager (Recommended)

Store secrets in 1Password, Bitwarden, or similar:
- Create a vault for each environment
- Store each secret as a secure note
- Use CLI to retrieve: `op read "op://Production/db_password/value"`

### Option 2: Encrypted Backup

Using `age` (modern encryption):
```bash
# Encrypt
tar -czf - secrets/ | age -r age1... > secrets-backup.tar.gz.age

# Decrypt
age -d secrets-backup.tar.gz.age | tar -xzf -
```

### Option 3: Cloud Secrets Manager

For production, consider:
- AWS Secrets Manager
- GCP Secret Manager
- HashiCorp Vault

## Troubleshooting

### Secret not found in container

```bash
# Check if file is mounted
docker exec mycontainer ls -la /run/secrets/

# Check environment variable
docker exec mycontainer printenv | grep _FILE
```

### Permission denied

```bash
# Check file permissions on host
ls -la secrets/staging/

# Should be 600 - fix if not
chmod 600 secrets/*/*.txt
```

### Secret value has extra whitespace

The scripts use `echo -n` to avoid trailing newlines. If you created manually:
```bash
# Check for newlines
cat -A secrets/staging/db_password.txt
# Should show no $ at end

# Fix
tr -d '\n' < secrets/staging/db_password.txt > temp && mv temp secrets/staging/db_password.txt
```
