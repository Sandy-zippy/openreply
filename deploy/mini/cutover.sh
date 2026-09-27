#!/bin/bash
# Move OpenReply off Railway: Postgres -> Supabase, Redis -> Upstash, worker -> Mac Mini.
# Run from the Air.
#   ./cutover.sh rehearse   copy the DB into Supabase and check both connections. Touches nothing live.
#   ./cutover.sh go         the real switch. Only on Sandy's say-so.
# Needs ~/.secrets/openreply-new-infra.env with:
#   NEW_DATABASE_URL  Supabase SESSION pooler (port 5432): restore + Mini worker
#   NEW_POOLED_URL    Supabase TRANSACTION pooler (port 6543): Vercel functions
#   NEW_REDIS_URL     Upstash rediss:// URL
set -euo pipefail
MODE=${1:-}; [[ "$MODE" == rehearse || "$MODE" == go ]] || { echo "usage: $0 rehearse|go"; exit 2; }
PG=$(brew --prefix libpq)/bin          # pg_dump 18; Homebrew psql 16 refuses Railway's PG18
REPO=/Users/sandy/HQ/System/tools/openreply
BK=/Users/sandy/HQ/System/tools/openreply-backups
MINI=sandys-mac-mini.local
RW_PROJECT=64407acd-5d07-4cff-838b-d59ad2b35e39 RW_ENV=2e433be6-0dbe-494f-a0de-854b2daeb276
RW_WORKER=2d618679-c84f-44ad-a894-f02cbb1bf2c6 RW_PG=21e8ef8b-e073-429f-ba02-20c6dc24341d
source ~/.secrets/deploy.env
source ~/.secrets/openreply-new-infra.env
rw() { curl -s https://backboard.railway.com/graphql/v2 -H "Authorization: Bearer $RAILWAY_API_TOKEN" -H 'Content-Type: application/json' -d "$1"; }
vc() { curl -s "https://api.vercel.com$2" -X "$1" -H "Authorization: Bearer $VERCEL_TOKEN" -H 'Content-Type: application/json' ${3:+-d "$3"}; }
counts() { "$PG/psql" "$1" -At -c 'select (select count(*) from "DmLog")||'"'"'/'"'"'||(select count(*) from "Automation")||'"'"'/'"'"'||(select count(*) from "ProcessedComment")'; }

echo "1. Stop the Railway worker (go only), so nothing writes during the copy"
if [[ $MODE == go ]]; then
  DEP=$(rw '{"query":"{ deployments(first:1, input:{serviceId:\"'$RW_WORKER'\", environmentId:\"'$RW_ENV'\"}){ edges{ node{ id status } } } }"}' | python3 -c "import json,sys;e=json.load(sys.stdin)['data']['deployments']['edges'];print(e[0]['node']['id'] if e else '')")
  [[ -n "$DEP" ]] && rw '{"query":"mutation { deploymentStop(id:\"'$DEP'\") }"}' && echo
fi

echo "2. Dump Railway Postgres (fall back to the newest backup if Railway is already gone)"
OLD_URL=$(rw '{"query":"{ variables(projectId:\"'$RW_PROJECT'\", environmentId:\"'$RW_ENV'\", serviceId:\"'$RW_PG'\") }"}' | python3 -c "
import json,sys
try:
  v=json.load(sys.stdin)['data']['variables'];print(f\"postgresql://{v['PGUSER']}:{v['PGPASSWORD']}@{v['RAILWAY_TCP_PROXY_DOMAIN']}:{v['RAILWAY_TCP_PROXY_PORT']}/{v['PGDATABASE']}\")
except Exception: print('')")
DUMP=$BK/railway-prod-$(date +%Y%m%d-%H%M).dump
if [[ -n "$OLD_URL" ]] && "$PG/pg_dump" -Fc "$OLD_URL" -f "$DUMP"; then OLD_COUNTS=$(counts "$OLD_URL")
else DUMP=$(ls -t $BK/railway-prod-*.dump | head -1); OLD_COUNTS="(railway unreachable)"; echo "   using backup $DUMP"; fi

echo "3. Restore into Supabase"
"$PG/pg_restore" --no-owner --no-acl --clean --if-exists -n public -d "$NEW_DATABASE_URL" "$DUMP" 2>&1 | grep -v "does not exist" || true
NEW_COUNTS=$(counts "$NEW_DATABASE_URL")
echo "   DmLog/Automation/ProcessedComment  railway=$OLD_COUNTS  supabase=$NEW_COUNTS"
[[ "$OLD_COUNTS" == "(railway unreachable)" || "$OLD_COUNTS" == "$NEW_COUNTS" ]] || { echo "COUNT MISMATCH, stopping"; exit 1; }

echo "4. Check Upstash"
[[ $(cd "$REPO" && REDIS_URL="$NEW_REDIS_URL" npx tsx -e 'import Redis from "ioredis";const r=new Redis(process.env.REDIS_URL!);r.ping().then(p=>{console.log(p);process.exit(0)})') == PONG ]] && echo "   PONG" || { echo "Upstash unreachable"; exit 1; }

[[ $MODE == rehearse ]] && { echo "REHEARSAL OK. Nothing live was touched."; exit 0; }

echo "5. Point Vercel at Supabase + Upstash and redeploy"
PID=$(vc GET /v9/projects/openreply | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
vc GET "/v9/projects/openreply/env" | python3 -c "
import json,sys
for e in json.load(sys.stdin)['envs']:
  if e['key'] in ('DATABASE_URL','REDIS_URL'): print(e['key'], e['id'])" | while read K ID; do
  V=$([[ $K == DATABASE_URL ]] && echo "$NEW_POOLED_URL" || echo "$NEW_REDIS_URL")
  vc PATCH "/v9/projects/openreply/env/$ID" "$(python3 -c 'import json,sys;print(json.dumps({"value":sys.argv[1]}))' "$V")" >/dev/null && echo "   $K updated"
done
# Supabase is in Seoul (ap-northeast-2), Upstash in Tokyo: run functions in Seoul, not iad1.
vc PATCH /v9/projects/openreply '{"resourceConfig":{"functionDefaultRegions":["icn1"]}}' | python3 -c "import json,sys;d=json.load(sys.stdin);print('   function region', d.get('resourceConfig',{}).get('functionDefaultRegions'), d.get('error',''))"
LAST=$(vc GET "/v6/deployments?projectId=$PID&target=production&limit=1" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployments'][0]['uid'])")
vc POST "/v13/deployments?forceNew=1" "{\"name\":\"openreply\",\"deploymentId\":\"$LAST\",\"target\":\"production\"}" | python3 -c "import json,sys;d=json.load(sys.stdin);print('   vercel redeploy', d.get('id'), d.get('error'))"

echo "6. Start the worker on the Mini"
ssh $MINI "cd ~/openreply && git pull -q && sed -i '' -e 's|^DATABASE_URL=.*|DATABASE_URL='\"'$NEW_DATABASE_URL'\"'|' -e 's|^REDIS_URL=.*|REDIS_URL='\"'$NEW_REDIS_URL'\"'|' ~/.secrets/openreply-worker.env && mkdir -p logs && cp deploy/mini/com.openreply.worker.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.openreply.worker.plist && echo '   launched'"

echo "7. Wait for the Mini's heartbeat on the live health check"
for i in $(seq 1 40); do
  H=$(curl -s https://openreply-ebon-mu.vercel.app/api/health)
  echo "$H" | grep -q '"hostname":"Sandys-Mac-mini' && { echo "   LIVE: $H" | cut -c1-300; echo "CUTOVER DONE. Test: comment a keyword from a test account."; exit 0; }
  sleep 15
done
echo "Mini heartbeat not seen after 10 min. Check ~/openreply/logs/worker.log on the Mini."; exit 1
