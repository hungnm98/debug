#!/usr/bin/env bash
# Uses the same PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSFILE/SSL settings as the benchmark.
set -euo pipefail
umask 077
export PGOPTIONS="${PGOPTIONS:-} -c statement_timeout=3000" PGAPPNAME=benchmark_monitor
while :; do
  psql -X -At -v ON_ERROR_STOP=1 -c "SELECT json_build_object('time',clock_timestamp(),'database',(SELECT row_to_json(d) FROM pg_stat_database d WHERE datname=current_database()),'wal',(SELECT row_to_json(w) FROM pg_stat_wal w),'pgbench_waits',(SELECT coalesce(json_agg(a),'[]'::json) FROM (SELECT state,wait_event_type,wait_event,count(*) FROM pg_stat_activity WHERE datname=current_database() AND usename=current_user AND application_name='pgbench' GROUP BY state,wait_event_type,wait_event) a))::jsonb;"
  sleep "${INTERVAL:-5}"
done
