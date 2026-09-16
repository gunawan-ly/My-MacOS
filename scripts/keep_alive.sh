#!/usr/bin/env bash
set -uo pipefail

KEEP_ALIVE_MINUTES="${KEEP_ALIVE_MINUTES:-355}"
INTERVAL=60

# Keluar sedikit sebelum timeout job (360 mnt) supaya step save/cache sempat jalan.
MAX_SECONDS=$((KEEP_ALIVE_MINUTES * 60))
STEPS=$((MAX_SECONDS / INTERVAL))

echo "Keep-alive: runner dipertahankan aktif selama ~${KEEP_ALIVE_MINUTES} menit."

for i in $(seq 1 "$STEPS"); do
  NOW="$(date '+%H:%M:%S')"
  ELAPSED=$((i * INTERVAL))
  REMAIN=$((MAX_SECONDS - ELAPSED))
  printf "[step %s/%s] %s | host crd: %s | berjalan ~%dm, sisa ~%dm\n" \
    "$i" "$STEPS" "$NOW" "${CRD_NAME:-N/A}" "$((ELAPSED / 60))" "$((REMAIN / 60))"
  sleep "$INTERVAL"
done

echo "Keep-alive selesai. Runner akan menunggu timeout GitHub (maks 6 jam)."