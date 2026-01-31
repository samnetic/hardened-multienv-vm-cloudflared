# Secrets Management

This directory contains secret files for each environment. **Secret files are NOT tracked in git.**

## Quick Start

```bash
# Create a secret
./scripts/secrets/create-secret.sh <environment> <secret_name>

# List all secrets
./scripts/secrets/list-secrets.sh

# Rotate a secret
./scripts/secrets/rotate-secret.sh <environment> <secret_name>
```

## Directory Structure

```
secrets/
├── .gitignore         # Ignores *.txt and other secret files
├── README.md          # This file
├── dev/               # Development secrets
│   └── .gitkeep
├── staging/           # Staging secrets
│   └── .gitkeep
└── production/        # Production secrets
    └── .gitkeep
```

## How File-Based Secrets Work

Instead of putting secrets in environment variables (visible in `docker inspect`), we:

1. **Store secrets in files** with restrictive permissions (`chmod 600`)
2. **Mount files into containers** at `/run/secrets/<name>` (read-only)
3. **Tell apps where to find them** via `*_FILE` environment variables

### Example compose.yml

```yaml
services:
  app:
    environment:
      - DATABASE_PASSWORD_FILE=/run/secrets/db_password
    volumes:
      - ../../secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
```

### Example app code (Node.js)

```javascript
const fs = require('fs');

function getSecret(name) {
  const filePath = process.env[`${name}_FILE`];
  if (filePath && fs.existsSync(filePath)) {
    return fs.readFileSync(filePath, 'utf8').trim();
  }
  // Fallback to direct env var for local dev
  return process.env[name];
}

const dbPassword = getSecret('DATABASE_PASSWORD');
```

### Example app code (Python)

```python
import os

def get_secret(name):
    file_path = os.environ.get(f'{name}_FILE')
    if file_path and os.path.exists(file_path):
        with open(file_path, 'r') as f:
            return f.read().strip()
    return os.environ.get(name)

db_password = get_secret('DATABASE_PASSWORD')
```

## Security Benefits

| Method | Security Issue |
|--------|---------------|
| `.env` files | Accidentally committed to git |
| Environment variables | Visible in `docker inspect`, process listings |
| **File-based secrets** | Only root/container can read, not in inspect output |

## Creating Secrets

### Interactive (recommended for passwords)
```bash
./scripts/secrets/create-secret.sh staging db_password
# Enter secret value: (hidden input)
# Confirm secret value: (hidden input)
```

### Generate random secret
```bash
./scripts/secrets/create-secret.sh production jwt_secret --generate 32
```

### Pipe from command
```bash
echo "my-api-key-123" | ./scripts/secrets/create-secret.sh dev api_key
```

### From password manager (1Password example)
```bash
op read "op://Vault/Item/password" | ./scripts/secrets/create-secret.sh production db_password
```

## Rotating Secrets

```bash
./scripts/secrets/rotate-secret.sh staging db_password
# Creates backup at secrets/staging/.backups/db_password.<timestamp>.txt
# Prompts for new value
```

After rotating, redeploy the affected containers:
```bash
docker compose -f apps/myapp/compose.yml up -d
```

## Backing Up Secrets

Secrets should be backed up securely (encrypted). Options:

1. **Password manager** (1Password, Bitwarden, HashiCorp Vault)
2. **Encrypted backup** using `age` or `gpg`:
   ```bash
   tar -czf - secrets/ | age -r age1... > secrets-backup.tar.gz.age
   ```
3. **Cloud secrets manager** (AWS Secrets Manager, GCP Secret Manager)

## Permissions

**Directories** should be `700` (owner only) and **files** should be `600` (owner read/write only):

```bash
# Set correct permissions after cloning or creating secrets
chmod 700 secrets/dev secrets/staging secrets/production
chmod 600 secrets/*/*.txt secrets/*/*.key 2>/dev/null || true

# Verify permissions
ls -la secrets/
ls -la secrets/*/
```

Expected output:
```
drwx------  secrets/dev/
drwx------  secrets/staging/
drwx------  secrets/production/
-rw-------  secrets/production/db_password.txt
```

## Environments

| Environment | Purpose | Who creates secrets |
|-------------|---------|---------------------|
| `dev` | Local development, playground | Developer |
| `staging` | Pre-production testing | CI/CD or admin |
| `production` | Live environment | Admin only |
