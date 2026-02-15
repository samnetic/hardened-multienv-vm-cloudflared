# Postgres Example (Backend-Only)

This is a production-style Postgres compose template:

- no published ports (tunnel-only model)
- attach to `*-backend` networks only
- file-based secrets (`POSTGRES_PASSWORD_FILE`)
- resource limits + pids limit

## Setup

1. Copy the example and create env + secret:

```bash
cp -r apps/examples/postgres /srv/apps/staging/postgres
cd /srv/apps/staging/postgres
cp .env.example .env

# Create a strong password (stored under /var/secrets/<env>/)
sudo /opt/hosting-blueprint/scripts/secrets/create-secret.sh staging postgres_password --generate 32
```

2. Start:

```bash
sudo docker compose --compatibility up -d
```

3. Connect from an app container on the same backend network:

- Host: `postgres`
- Port: `5432`
- User: `${POSTGRES_USER}`
- DB: `${POSTGRES_DB}`

## Security Notes

- Keep Postgres on backend networks only (no ports, no web network).
- Back up the `postgres_data` volume.
- Consider a separate VPS for databases if your threat model requires it.
