#!/usr/bin/env bash
set -euo pipefail
umask 077
BENCHMARK="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/pg_bench_20idx.sh"
for cmd in psql pgbench; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }; done
export ROWS="${ROWS:-2000000}" DURATION="${DURATION:-120}" CLIENTS="${CLIENTS:-1 16 64}"
[[ "$ROWS" =~ ^[1-9][0-9]*$ && "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo 'ROWS and DURATION must be positive integers' >&2; exit 1; }
for c in $CLIENTS; do [[ "$c" =~ ^[1-9][0-9]*$ ]] || { echo 'CLIENTS must contain positive integers' >&2; exit 1; }; done
[[ -n "$CLIENTS" ]] || { echo 'CLIENTS is empty' >&2; exit 1; }
if [ "$#" -eq 0 ]; then set -- off local on; fi
seen_modes=" "
for mode in "$@"; do
  [[ "$seen_modes" != *" $mode "* ]] || { echo "Duplicate mode: $mode" >&2; exit 1; }
  seen_modes+="$mode "
  case "$mode" in off|local|on|remote_write|remote_apply) ;; *) echo "Unknown commit mode: $mode" >&2; exit 1;; esac
done
base_options="${PGOPTIONS:-} -c search_path=public"
export PGOPTIONS="$base_options"
SQL=(psql -X -At -v ON_ERROR_STOP=1)
check_absent() {
  [ "$("${SQL[@]}" -c "SELECT to_regclass('public.bench_orders_20idx') IS NULL AND NOT pg_is_in_recovery() AND current_setting('transaction_read_only')='off' AND has_schema_privilege(current_user,'public','USAGE') AND has_schema_privilege(current_user,'public','CREATE')")" = t ] || {
    echo 'Requires writable primary, USAGE/CREATE on public, and no existing public.bench_orders_20idx' >&2; exit 1;
  }
}
check_absent
had_trgm="$("${SQL[@]}" -c "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_trgm')")"
mkdir -p "${RESULTS_ROOT:-./pgbench-results}"
run_dir="$(mktemp -d "${RESULTS_ROOT:-./pgbench-results}/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
run_dir="$(cd "$run_dir" && pwd)"
owned_table=0
finish() {
  code=$?
  trap - EXIT
  set +e
  if [ "$owned_table" -eq 1 ]; then
    "$BENCHMARK" clean >> "$run_dir/cleanup-on-exit.log" 2>&1
    cleanup_code=$?; [ "$cleanup_code" -eq 0 ] || code=$cleanup_code
  fi
  if [ "$had_trgm" = f ]; then
    "${SQL[@]}" -c "DO \$\$ BEGIN IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_trgm' AND extowner=(SELECT oid FROM pg_roles WHERE rolname=current_user)) THEN DROP EXTENSION pg_trgm; END IF; END \$\$;" >> "$run_dir/extension-cleanup.log" 2>&1
    cleanup_code=$?; [ "$cleanup_code" -eq 0 ] || code=$cleanup_code
  fi
  echo "Results: $run_dir (exit $code)"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for mode in "$@"; do
  export PGOPTIONS="$base_options -c synchronous_commit=$mode" OUTDIR="$run_dir/$mode"
  [ ! -e "$OUTDIR" ] || { echo "Duplicate mode: $mode" >&2; exit 1; }
  mkdir "$OUTDIR"
  check_absent
  "${SQL[@]}" -c 'SHOW synchronous_commit' > "$OUTDIR/synchronous-commit.txt"
  grep -qx "$mode" "$OUTDIR/synchronous-commit.txt"
  echo "[$(date +%T)] $mode: init $ROWS rows"
  date -u +%FT%TZ > "$OUTDIR/start-utc.txt"
  owned_table=1
  "$BENCHMARK" init > "$OUTDIR/init.log" 2>&1
  "${SQL[@]}" -c "SELECT json_build_object('rows',count(*),'indexes',(SELECT count(*) FROM pg_index WHERE indrelid='public.bench_orders_20idx'::regclass),'trgm',to_regclass('public.b20_note_trgm') IS NOT NULL) FROM public.bench_orders_20idx" > "$OUTDIR/initial-count.json"
  [ "$("${SQL[@]}" -c "SELECT count(*)=$ROWS AND (SELECT count(*) FROM pg_index WHERE indrelid='public.bench_orders_20idx'::regclass)=20 AND to_regclass('public.b20_note_trgm') IS NOT NULL FROM public.bench_orders_20idx")" = t ] || { echo 'Expected ROWS rows and all 20 indexes including GIN trigram; see init.log' >&2; exit 1; }
  "$BENCHMARK" run 2>&1 | tee "$OUTDIR/run.log"
  "$BENCHMARK" clean > "$OUTDIR/clean.log" 2>&1
  check_absent
  owned_table=0
  echo t > "$OUTDIR/cleanup-verified.txt"
  date -u +%FT%TZ > "$OUTDIR/end-utc.txt"
done
