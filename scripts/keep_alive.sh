#!/usr/bin/env bash
set -uo pipefail

KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"
CRD_NAME="${CRD_NAME:-mac-${GITHUB_RUN_ID:-runner}}"
INTERVAL=60

# Keluar sedikit sebelum timeout job (360 mnt) supaya step save/cache sempat jalan.
MAX_SECONDS=$((KEEP_ALIVE_MINUTES * 60))
STEPS=$((MAX_SECONDS / INTERVAL))

echo "Keep-alive: runner dipertahankan aktif selama ~${KEEP_ALIVE_MINUTES} menit."

for ((i=1; i<=STEPS; i++)); do
  echo "[keep-alive $i/$STEPS] $(date -u +%H:%M:%S) - $CRD_NAME masih aktif"
  sleep $INTERVAL
done

echo "Keep-alive selesai. Runner akan menunggu timeout GitHub (maks 6 jam)."
