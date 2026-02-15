# Secrets Management

This guide explains how secrets work in this template and best practices for managing them.

## Overview

We use **file-based secrets** instead of environment variables. This provides the same security as Docker Swarm secrets without requiring Swarm mode.

## Why File-Based Secrets?

| Method | Problem |
|--------|---------|
| `.env` files | Easily committed to git by accident |
| Environment variables | Visible in `sudo docker inspect`, process listings, logs |
| Docker Swarm secrets | Requires Swarm mode (deprecated/complex) |
| **File-based secrets** | Secure, simple, works with plain Compose |

### Security Benefits

1. **Not in sudo docker inspect** - `sudo docker inspect container` won't show secrets
2. **Not in process listings** - `ps aux` won't expose them
3. **Permissions enforced** - Files are `root:hosting-secrets` with mode `640`
4. **Read-only mount** - Containers can't modify secrets
5. **Kept out of git** - Secrets live in `/var/secrets` (outside repositories)

## How It Works

### 1. Create Secret File

```bash
./scripts/secrets/create-secret.sh staging db_password
# Enter secret value: (hidden)
# Confirm: (hidden)
# ✓ Secret created: staging/db_password
```

This creates: `/var/secrets/staging/db_password.txt` with `root:hosting-secrets` ownership and `chmod 640`.

### 2. Mount in compose.yml

```yaml
services:
  app:
    group_add:
      - "1999" # hosting-secrets (so non-root containers can read /run/secrets/*)
    volumes:
      # Mount secret file to /run/secrets/ (read-only)
      - /var/secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
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
op read "op://Vault/Item/password" | ./scripts/secrets/create-secret.sh production db_password
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
# Creates backup: /var/secrets/staging/.backups/db_password.20240115120000.txt
# Prompts for new value
```

After rotating, redeploy affected containers:
```bash
sudo docker compose --compatibility -f apps/myapp/compose.yml up -d
```

## Directory Structure

```
/var/secrets/
├── dev/
│   ├── db_password.txt     # Dev database password
│   └── api_key.txt         # Test API keys
├── staging/
│   ├── db_password.txt
│   └── api_key.txt
└── production/
    ├── db_password.txt     # Strong, unique, rotated regularly
    └── api_key.txt         # Production API keys
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

- Commit secrets to git (keep them in `/var/secrets`)
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
sudo tar -czf - /var/secrets/ | age -r age1... > secrets-backup.tar.gz.age

# Decrypt
age -d secrets-backup.tar.gz.age | tar -xzf -
```

### Option 3: Cloud Secrets Manager

For production, consider:
- AWS Secrets Manager
- GCP Secret Manager
- HashiCorp Vault

## Optional: Encrypted `.env` in Git (SOPS + age)

This blueprint's GitOps workflow supports an optional convention:

- Commit encrypted dotenv files: `.env.<env>.enc` (SOPS-encrypted, dotenv format)
- Decrypt on the VM during deploy to: `.env.<env>`

This is useful when you need to ship non-file secrets to an app that expects dotenv.

### VM Setup (One-Time)

On the VM, install `sops` + `age` and generate/restore an age key:

```bash
sudo /opt/hosting-blueprint/scripts/security/setup-sops-age.sh
```

This creates (by default): `/etc/sops/age/keys.txt`.

### Security Notes

- The age private key can decrypt your secrets: treat it like a production root key.
- Prefer `/var/secrets` file mounts for secrets where possible (simpler and less crypto/key management).

## Troubleshooting

### Secret not found in container

```bash
# Check if file is mounted
sudo docker exec mycontainer ls -la /run/secrets/

# Check environment variable
sudo docker exec mycontainer printenv | grep _FILE
```

### Permission denied

```bash
# Check file permissions on host
sudo ls -la /var/secrets/staging/

# Expected (system secrets):
#   directories: 750 root:hosting-secrets
#   files:       640 root:hosting-secrets
sudo chown -R root:hosting-secrets /var/secrets
sudo find /var/secrets -type d -exec chmod 750 {} \;
sudo find /var/secrets -type f -name '*.txt' -exec chmod 640 {} \;
```

### Secret value has extra whitespace

The scripts use `echo -n` to avoid trailing newlines. If you created manually:
```bash
# Check for newlines
sudo cat -A /var/secrets/staging/db_password.txt
# Should show no $ at end

# Fix
sudo sh -c "tr -d '\\n' < /var/secrets/staging/db_password.txt > /tmp/secret.tmp && mv /tmp/secret.tmp /var/secrets/staging/db_password.txt"
```

## Local Development (Optional)

If you're running this repository locally (no `/var/secrets`), you can use a repo-local path:

```bash
SECRETS_DIR=./secrets ./scripts/secrets/create-secret.sh dev api_key
SECRETS_DIR=./secrets ./scripts/secrets/list-secrets.sh dev
```
