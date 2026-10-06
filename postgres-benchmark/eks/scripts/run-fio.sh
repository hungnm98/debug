#!/usr/bin/env bash
set -euo pipefail
umask 077
root="${BENCHMARK_VOLUME:-/var/lib/postgresql/data}"
scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
size="${FIO_SIZE:-10G}"
fsync_size="${FIO_FSYNC_SIZE:-2G}"
runtime="${FIO_RUNTIME:-60}"
mixed_runtime="${FIO_MIXED_RUNTIME:-300}"
minimum_free="${FIO_MIN_FREE_BYTES:-55834574848}"
for value in "$runtime" "$mixed_runtime" "$minimum_free"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo 'Durations/free-space threshold must be positive integers' >&2; exit 1; }
done
for value in "$size" "$fsync_size"; do
  [[ "$value" =~ ^[1-9][0-9]*[MG]$ ]] || { echo 'File sizes must use integer M or G' >&2; exit 1; }
done
exec 9> "$root/.benchmark.lock"
echo 'Waiting for shared benchmark lock (fio)'
flock -w 1800 9
free="$(df -B1 --output=avail "$root" | tail -1 | tr -d ' ')"
[ "$free" -ge "$minimum_free" ] || { echo "Need at least $minimum_free free bytes; found $free" >&2; exit 1; }
mkdir -p "$root/benchmark-results"
result="$(mktemp -d "$root/benchmark-results/fio-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
scratch="$(mktemp -d "$root/.fio-XXXXXX")"
monitor_pid=''
finish() {
  code=$?
  trap - EXIT
  set +e
  if [ -n "$monitor_pid" ]; then kill "$monitor_pid" 2>/dev/null; wait "$monitor_pid" 2>/dev/null; fi
  rm -rf -- "$scratch"
  echo "$code" > "$result/exit-code.txt"
  echo "Results: $result (exit $code; scratch files removed)"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{ date -u +%FT%TZ; fio --version; df -h "$root"; cat /proc/self/mountinfo; } > "$result/environment.txt"
bash "$scripts/monitor-cgroup.sh" > "$result/container-resources.log" &
monitor_pid="$!"
common=(--directory="$scratch" '--filename_format=fio.$jobnum' --ioengine=libaio --direct=1 --size="$size" --iodepth=32 --numjobs=4 --group_reporting --output-format=json)
run() {
  name="$1"; shift
  echo "[$(date -u +%FT%TZ)] $name"
  # Keep diagnostics on stderr separate from the JSON report.
  # --output merges some fio diagnostics into the JSON file.
  fio --name="$name" "$@" > "$result/$name.json" 2> "$result/$name.stderr.log"
  cat "$result/$name.stderr.log" >&2
}
# Write every block first: random reads must not measure sparse/unwritten extents.
run prepare "${common[@]}" --rw=write --bs=1M --end_fsync=1
run randread-4k "${common[@]}" --rw=randread --bs=4k --runtime="$runtime" --time_based
run randwrite-4k "${common[@]}" --rw=randwrite --bs=4k --runtime="$runtime" --time_based
run randread-8k "${common[@]}" --rw=randread --bs=8k --runtime="$runtime" --time_based
run randwrite-8k "${common[@]}" --rw=randwrite --bs=8k --runtime="$runtime" --time_based
run fsync-test --directory="$scratch" --filename=fsync.bin --ioengine=sync --rw=write --bs=8k --size="$fsync_size" --fdatasync=1 --runtime="$runtime" --time_based --output-format=json
run mixed "${common[@]}" --rw=randrw --rwmixread=70 --bs=8k --runtime="$mixed_runtime" --time_based
