#!/usr/bin/env bash
# =================================================================
# Repo Validation (static checks)
# =================================================================
# Runs cheap, deterministic checks to catch obvious regressions:
# - bash syntax checks for shell scripts
# - YAML parse validation
# - Python syntax check for the deploy tool (without writing .pyc files)
#
# Usage:
#   ./scripts/dev/validate-repo.sh
# =================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "==> bash -n (scripts/ + config/bin shell wrappers)"

# Top-level entrypoints
for f in setup.sh bootstrap.sh; do
  if [ -f "$f" ]; then
    bash -n "$f"
  fi
done

# Shell scripts
find scripts -type f -name '*.sh' -print0 | xargs -0 -n 1 bash -n

# Shell wrappers in config/bin (not necessarily .sh)
for f in config/bin/hosting-ci-ssh config/bin/hosting-cloudflared-upgrade; do
  if [ -f "$f" ]; then
    bash -n "$f"
  fi
done

echo "==> shellcheck (optional)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x setup.sh bootstrap.sh
  find scripts -type f -name '*.sh' -print0 | xargs -0 shellcheck -x
  for f in config/bin/hosting-ci-ssh config/bin/hosting-cloudflared-upgrade; do
    if [ -f "$f" ]; then
      shellcheck -x "$f"
    fi
  done
  echo "shellcheck OK"
else
  echo "SKIP: shellcheck not available"
fi

echo "==> YAML parse (apps/, infra/, config/, docs/)"
python3 - <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except Exception as e:
    print("ERROR: missing PyYAML. On Ubuntu: sudo apt-get install -y python3-yaml")
    raise

paths = set()
for ext in ("*.yml", "*.yaml"):
    paths.update(Path(".").rglob(ext))

failed = False
for p in sorted(paths):
    try:
        yaml.safe_load(p.read_text())
    except Exception as e:
        failed = True
        print(f"YAML ERROR: {p}: {e}")

if failed:
    sys.exit(1)

print(f"YAML OK: {len(paths)} file(s)")
PY

echo "==> docker compose config (--no-interpolate)"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  # Validate all compose files without requiring .env files to exist.
  mapfile -t compose_files < <(find apps infra -type f \( -name 'compose.yml' -o -name 'compose.*.yml' -o -name 'docker-compose.yml' -o -name 'docker-compose.*.yml' \) | sort)
  failures=0
  for f in "${compose_files[@]}"; do
    dir="$(dirname "$f")"
    base="$(basename "$f")"
    if ! (cd "$dir" && docker compose -f "$base" config --no-interpolate >/dev/null 2>&1); then
      echo "COMPOSE CONFIG ERROR: $f"
      (cd "$dir" && docker compose -f "$base" config --no-interpolate 2>&1 | head -50) || true
      failures=$((failures + 1))
    fi
  done

  # Validate known overlays as merged configs (common footgun).
  overlays=(
    "apps/examples/python-fastapi/compose.yml apps/examples/python-fastapi/compose.local.yml"
    "apps/examples/simple-api/compose.yml apps/examples/simple-api/compose.local.yml"
    "infra/monitoring-agent/compose.yml infra/monitoring-agent/compose.cadvisor.yml"
  )
  for pair in "${overlays[@]}"; do
    f1="${pair%% *}"
    f2="${pair#* }"
    d1="$(dirname "$f1")"

    # Some examples declare `env_file: .env` (container env), which `docker compose config`
    # insists on reading. Create a temporary .env from .env.example if needed.
    tmp_env=""
    if [ ! -f "${d1}/.env" ]; then
      if [ -f "${d1}/.env.example" ]; then
        cp "${d1}/.env.example" "${d1}/.env"
      else
        : > "${d1}/.env"
      fi
      tmp_env="${d1}/.env"
    fi

    # For overlays, do NOT use --no-interpolate: docker compose normalizes `networks:` into
    # a map during merges, and variable placeholders become invalid keys.
    if ! (cd "$d1" && docker compose -f "$(basename "$f1")" -f "$(basename "$f2")" config >/dev/null 2>&1); then
      echo "COMPOSE CONFIG ERROR (overlay): $f1 + $f2"
      (cd "$d1" && docker compose -f "$(basename "$f1")" -f "$(basename "$f2")" config 2>&1 | head -80) || true
      failures=$((failures + 1))
    fi

    # Cleanup temporary .env if we created it.
    if [ -n "$tmp_env" ]; then
      rm -f "$tmp_env"
    fi
  done

  if [ "$failures" -gt 0 ]; then
    echo "ERROR: docker compose config failed for ${failures} file(s)"
    exit 1
  fi
  echo "docker compose config OK: ${#compose_files[@]} file(s)"
else
  echo "SKIP: docker compose not available"
fi

echo "==> python syntax check"
python3 - <<'PY'
from pathlib import Path

paths = [
    Path("config/bin/hosting-deploy"),
    Path("scripts/cloudflare-access/validate-jwt.py"),
    Path("apps/examples/python-fastapi/src/main.py"),
]

for p in paths:
    src = p.read_text(encoding="utf-8")
    compile(src, str(p), "exec")
PY

echo "==> node syntax check"
if command -v node >/dev/null 2>&1; then
  node --check scripts/cloudflare-access/validate-jwt.js >/dev/null
  node --check apps/examples/simple-api/src/server.js >/dev/null
  echo "node OK"
else
  echo "SKIP: node not available"
fi

echo "OK"
