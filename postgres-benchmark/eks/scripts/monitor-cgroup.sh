#!/usr/bin/env bash
set -euo pipefail
while :; do
  date -u +%FT%TZ
  # Raw cumulative counters: CPU delta / time; memory.current is bytes.
  for file in cpu.max cpu.stat memory.current memory.max memory.stat io.stat; do
    if [ -r "/sys/fs/cgroup/$file" ]; then
      echo "[$file]"
      cat "/sys/fs/cgroup/$file"
    fi
  done
  # EKS nodes on cgroup v1: preserve their equivalent counters.
  for file in cpuacct/cpuacct.usage memory/memory.usage_in_bytes blkio/blkio.throttle.io_service_bytes; do
    if [ -r "/sys/fs/cgroup/$file" ]; then
      echo "[$file]"
      cat "/sys/fs/cgroup/$file"
    fi
  done
  sleep 1
done
