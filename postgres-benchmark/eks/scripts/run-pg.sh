#!/usr/bin/env bash
set -euo pipefail
umask 077
mode="${1:?Expected off or on}"
case "$mode" in off|on) ;; *) echo 'Expected off or on' >&2; exit 1;; esac
root="${BENCHMARK_VOLUME:-/var/lib/postgresql/data}"
scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec 9> "$root/.benchmark.lock"
echo "Waiting for shared benchmark lock ($mode)"
flock -w 1800 9
unset PGHOSTADDR PGOPTIONS PGSERVICE PGSERVICEFILE PGPASSFILE
export PGHOST="${PGHOST:-postgres.postgres-benchmark.svc.cluster.local}" PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-postgres}" PGSSLMODE=disable PGCONNECT_TIMEOUT=5
export PGPASSWORD="$(cat "${POSTGRES_PASSWORD_FILE:?}")"
mkdir -p "$root/benchmark-results"
result="$(mktemp -d "$root/benchmark-results/pg-$mode-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
export RESULTS_ROOT="$result"
monitor_pids=()
finish() {
  code=$?
  trap - EXIT
  set +e
  for pid in "${monitor_pids[@]}"; do kill "$pid" 2>/dev/null; done
  for pid in "${monitor_pids[@]}"; do wait "$pid" 2>/dev/null; done
  # Flush pending cleanup writes before the next workload gets the lock.
  psql -X -v ON_ERROR_STOP=1 -c CHECKPOINT >> "$result/checkpoint.log" 2>&1
  checkpoint_code=$?
  if [ "$code" -eq 0 ]; then code=$checkpoint_code; fi
  echo "$code" > "$result/exit-code.txt"
  echo "Results: $result (exit $code)"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if pg_isready -q -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -t 5; then ready=true; break; fi
  sleep 5
done
[ "$ready" = true ] || { echo 'PostgreSQL endpoint was not ready' >&2; exit 1; }
{
  date -u +%FT%TZ
  pgbench --version
  psql -X -At -c 'SELECT version(); SHOW synchronous_commit; SHOW fsync; SHOW full_page_writes;'
  echo "Endpoint: $PGHOST:$PGPORT/$PGDATABASE"
  df -h "$root"
  cat /proc/self/mountinfo
} > "$result/environment.txt"
bash "$scripts/monitor_db.sh" > "$result/database.jsonl" 2> "$result/database-monitor.log" &
monitor_pids+=("$!")
bash "$scripts/monitor-cgroup.sh" > "$result/container-resources.log" &
monitor_pids+=("$!")
bash "$scripts/run_commit_modes.sh" "$mode" 2>&1 | tee "$result/console.log"
