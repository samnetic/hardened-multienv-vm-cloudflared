# Production Docker Compose Hardening (Template + Checklist)

This blueprint assumes:

- **tunnel-only** access (no public ports)
- **least privilege** containers
- **resource limits** to reduce blast radius
- **file-based secrets** (not `.env` secrets)

Use `apps/_template/compose.yml` as your base and treat the checklist below as the minimum bar for production.

## Checklist (Security-First Defaults)

- Pin images (tag or digest). Avoid `:latest`.
- No published ports by default.
  - If you must publish, bind to loopback only: `127.0.0.1:PORT:PORT`
- `security_opt: ["no-new-privileges:true"]`
- `cap_drop: ["ALL"]` and add back only what you need.
- Prefer `read_only: true` and add `tmpfs` for writable paths (`/tmp`, sometimes `/var/run`).
- Set `pids_limit` (fork-bomb protection).
- Set CPU + memory limits (`deploy.resources.limits`) and reservations.
  - Note: `deploy.resources` limits are only enforced by `docker compose` when using `--compatibility`.
    The blueprint deploy tool (`hosting-deploy`) uses `--compatibility` automatically.
- Add a `healthcheck` for every service with `restart: unless-stopped`.
- Avoid:
  - `privileged: true`
  - `network_mode: host`
  - `pid: host`
  - `ipc: host`
  - `userns_mode: host`
  - `/var/run/docker.sock` mounts
- Prefer dedicated networks:
  - `*-web` for app frontends (reachable via reverse proxy)
  - `*-backend` as `internal: true` for databases/queues
- Use file-based secrets:
  - `/var/secrets/<env>/*.txt` → `/run/secrets/*` (read-only)
  - run containers as non-root and add `group_add: ["1999"]` to read secrets
- Keep logs bounded:
  - Prefer Docker daemon `log-driver=local` + `max-size/max-file`
  - If you override logging per-service, ensure rotation is set

## Template Notes

The template at `apps/_template/compose.yml` includes:

- `no-new-privileges`
- `cap_drop: ALL`
- `read_only` + `tmpfs`
- `pids_limit`
- CPU/memory limits
- healthcheck example
- secrets mounts and `group_add: ["1999"]`

## Production Layout Recommendation

For each environment:

- `/srv/apps/dev/<app>/compose.yml` on `dev-web` + `dev-backend` (dev-backend is host-accessible)
- `/srv/apps/staging/<app>/compose.yml` on `staging-web` + `staging-backend` (backend internal)
- `/srv/apps/production/<app>/compose.yml` on `prod-web` + `prod-backend` (backend internal)

## Common Hardening Patterns

### Loopback-only ports (safe for cloudflared)

```yaml
ports:
  - "127.0.0.1:3000:3000"
```

### Read-only filesystem

```yaml
read_only: true
tmpfs:
  - /tmp:size=64M,mode=1777
```

### Minimal capabilities

```yaml
cap_drop:
  - ALL
# cap_add:
#   - NET_BIND_SERVICE
```

### File-based secrets

```yaml
environment:
  - DATABASE_PASSWORD_FILE=/run/secrets/db_password
group_add:
  - "1999"
volumes:
  - /var/secrets/${ENVIRONMENT}/db_password.txt:/run/secrets/db_password:ro
```

## Deploy Policy Guardrails

The hardened deploy tool (`hosting-deploy`) enforces guardrails by default, including:

- deny docker.sock mounts
- deny privileged and host namespaces
- deny ports publishing (tunnel-only)
- deny builds on the VM by default

Optional strictness is configured via `/etc/hosting-blueprint/deploy-policy.env` (root-owned).
