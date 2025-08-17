#!/usr/bin/env bash
# task-runner.sh
# Run API-Traffic-Generator tasks with nice logs, status codes, and pacing.

set -uo pipefail

# -----------------------------
# Config (override via env or flags)
# -----------------------------
DOCKER_IMAGE="${DOCKER_IMAGE:-api-traffic-generator:latest}"

# If you want one URL for everything, set BASE_URL.
# If you want different URLs for motel vs reservation services, set BASE_URL_MOTEL and BASE_URL_RESV.
BASE_URL_DEFAULT="${BASE_URL:-http://host.docker.internal:8085}"
BASE_URL_MOTEL="${BASE_URL_MOTEL:-$BASE_URL_DEFAULT}"
BASE_URL_RESV="${BASE_URL_RESV:-${BASE_URL2:-http://host.docker.internal:8086}}"

# Add-host flag to reach host services from Docker on Linux; safe to keep on Mac as well.
ADD_HOST_FLAG="${ADD_HOST_FLAG:---add-host=host.docker.internal:host-gateway}"

# Delay (seconds) between tasks
DELAY_SECS="${DELAY_SECS:-2}"

# -----------------------------
# Helpers
# -----------------------------
ts() { date +"%Y-%m-%d %H:%M:%S"; }

print_hdr() {
  local msg="$1"
  echo
  echo "============================================================"
  echo "[$(ts)] $msg"
  echo "============================================================"
}

pause_then_next() {
  local next_task="$1"
  echo "[$(ts)] Pausing for ${DELAY_SECS}s..."
  sleep "${DELAY_SECS}"
  echo "[$(ts)] Running next task: ${next_task}"
}

run_task() {
  local task_name="$1"; shift
  local base_url="$1"; shift

  # Make a local array and fill it *safely* under `set -u`
  local -a envs=()
  if (($# > 0)); then
    envs=("$@")
  fi

  print_hdr "Starting task: ${task_name}"

  # Build docker -e args
  local -a docker_env_flags=(-e "TASK=${task_name}" -e "BASE_URL=${base_url}")
  # Safe expansion even if envs is empty
  for kv in "${envs[@]:-}"; do
    docker_env_flags+=(-e "$kv")
  done

  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Using DOCKER_IMAGE=${DOCKER_IMAGE}"
  echo "[$(date +"%Y-%m-%d %H:%M:%S")] Using BASE_URL=${base_url}"

  # Print extras only if present (safe length check under nounset)
  if ((${#envs[@]:-0})); then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Extra env: ${envs[*]}"
  fi

  docker run --rm ${ADD_HOST_FLAG} "${docker_env_flags[@]}" "${DOCKER_IMAGE}"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ✅ Completed task: ${task_name} (exit code 0)"
  else
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ❌ Completed task: ${task_name} with errors (exit code ${rc})"
  fi

  return $rc
}


# Graceful Ctrl-C
trap 'echo; echo "[$(ts)] Interrupted. Exiting."; exit 130' INT

# -----------------------------
# Sequence
# -----------------------------

# 1) post_motel_chain (motel service)
run_task "post_motel_chain" "${BASE_URL_MOTEL}" \
  "LOG_LEVEL=DEBUG" \
|| true
pause_then_next "ping_once"

# 2) ping_once (motel service)
run_task "ping_once" "${BASE_URL_MOTEL}" \
|| true
pause_then_next "get_motel_chains"

# 3) get_motel_chains (motel service)
run_task "get_motel_chains" "${BASE_URL_MOTEL}" \
  "PAGE_SIZE=10" \
|| true
pause_then_next "get_motels"

# 4) get_motels (motel service)
run_task "get_motels" "${BASE_URL_MOTEL}" \
  "PAGE_SIZE=10" \
  "CHAIN_LOOKUP=true" \
|| true
pause_then_next "seed_room_categories"

# 5) seed_room_categories (motel service)
run_task "seed_room_categories" "${BASE_URL_MOTEL}" \
  "PAGE_SIZE=25" \
  "ONLY_ACTIVE=true" \
  "ROOM_CATEGORY_STATUS=Active" \
  "ROOM_CATEGORY_PATH=/motelApi/v1/motelRoomCategories" \
|| true
pause_then_next "seed_motel_rooms"

# 6) seed_motel_rooms (motel service)
run_task "seed_motel_rooms" "${BASE_URL_MOTEL}" \
  "FLOOR_START=0" \
  "FLOOR_END=3" \
  "ROOMS_PER_FLOOR=5" \
  "ROOM_STATUS=Active" \
|| true
pause_then_next "reservation_ping_once"

# 7) reservation_ping_once (reservation service)
run_task "reservation_ping_once" "${BASE_URL_RESV}" \
|| true
pause_then_next "reservation_all_motels"

# 8) reservation_all_motels (reservation service)
run_task "reservation_all_motels" "${BASE_URL_RESV}" \
  "START_PAGE=1" \
  "RESV_PER_PAGE=10" \
  "RESV_PAGE_PARAM=page" \
  "RESV_PER_PAGE_PARAM=per_page" \
|| true
pause_then_next "reservation_from_availability"

# 9) reservation_from_availability (reservation service)
run_task "reservation_from_availability" "${BASE_URL_RESV}" \
  "START_PAGE=1" \
  "RESV_PER_PAGE=50" \
  "RESV_PAGE_PARAM=page" \
  "RESV_PER_PAGE_PARAM=per_page" \
  "RESERVATION_NAME=John Doe" \
  "RESERVATION_EMAIL=john.doe@example.com" \
  "RESERVATION_STATUS=Confirmed" \
|| true
pause_then_next "reservation_all_bookings"

# 10) reservation_all_bookings (reservation service)
run_task "reservation_all_bookings" "${BASE_URL_RESV}" \
  "START_PAGE=1" \
  "BOOKINGS_PER_PAGE=10" \
  "BOOKINGS_PAGE_PARAM=page" \
  "BOOKINGS_PER_PAGE_PARAM=per_page" \
|| true
pause_then_next "reservation_by_ids"

# 11) reservation_by_ids (reservation service)
run_task "reservation_by_ids" "${BASE_URL_RESV}" \
  "START_PAGE=1" \
  "BOOKINGS_PER_PAGE=25" \
  "BOOKINGS_PAGE_PARAM=page" \
  "BOOKINGS_PER_PAGE_PARAM=per_page" \
|| true

echo
echo "[$(ts)] 🎉 All tasks attempted."
