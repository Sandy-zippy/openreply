#!/bin/bash
# Runs the OpenReply DM worker on the Mac Mini. launchd (com.openreply.worker) keeps it alive.
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
cd "$(dirname "$0")/../.."
set -a; source "$HOME/.secrets/openreply-worker.env"; set +a
# Refuse to start until cutover has filled in the real database and Redis.
if [[ "$DATABASE_URL" == PENDING* || "$REDIS_URL" == PENDING* ]]; then
  echo "$(date) openreply-worker: DATABASE_URL/REDIS_URL not set yet, not starting" >&2
  sleep 300; exit 1
fi
exec npx tsx worker/dm-worker.ts
