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

echo "==> python syntax check (config/bin/hosting-deploy)"
python3 - <<'PY'
from pathlib import Path

p = Path("config/bin/hosting-deploy")
src = p.read_text(encoding="utf-8")
compile(src, str(p), "exec")
PY

echo "OK"
