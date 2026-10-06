#!/usr/bin/env bash
set -euo pipefail
mode="${1:?Expected off or on}"
case "$mode" in off|on) ;; *) exit 1;; esac
namespace="${POD_NAMESPACE:?}"
ready=false
for ((attempt=0; attempt<60; attempt++)); do
  if [ "$(kubectl get pod postgres-0 -n "$namespace" -o jsonpath='{.status.containerStatuses[?(@.name=="postgres")].ready}')" = true ]; then
    ready=true; break
  fi
  sleep 5
done
[ "$ready" = true ] || { echo 'postgres-0 was not ready within 300 seconds' >&2; exit 1; }
exec kubectl exec -n "$namespace" postgres-0 -c postgres -- bash /opt/benchmark/run-pg.sh "$mode"
