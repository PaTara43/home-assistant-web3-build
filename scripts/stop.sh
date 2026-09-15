#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  # shellcheck disable=SC1091
  source ./scripts/packages.env
  set +a
fi
# Stop everything regardless of which profiles are active.
docker compose --profile z2m --profile z2m2 --profile matter --profile matter-hub down

echo "Stack stopped."