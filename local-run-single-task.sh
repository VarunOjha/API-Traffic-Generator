#!/usr/bin/env bash
# run-single-task.sh
# Run a single API-Traffic-Generator task by name, with robust env handling.

set -uo pipefail

# -----------------------------
# Config (override via env or flags)
# -----------------------------
DOCKER_IMAGE="${DOCKER_IMAGE:-api-traffic-generator:latest}"

BASE_URL_DEFAULT="${BASE_URL:-http://host.docker.internal:8085}"
BASE_URL_MOTEL="${BASE_URL_MOTEL:-$BASE_URL_DEFAULT}"
BASE_URL_RESV="${BASE_URL_RESV:-${BASE_URL2:-http://host.docker.internal:8086}}"

# If you don't want add-host, set: ADD_HOST_FLAG=""
ADD_HOST_FLAG="${ADD_HOST_FLAG:---add-host=host.docker.internal:host-gateway}"

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

# Trim leading/trailing whitespace (POSIX-ish)
trim() {
  local s="${1:-}"
  # shellcheck disable=SC2001
  s="$(echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  printf '%s' "$s"
}

# Return 0 if looks like KEY=VALUE (KEY must be non-empty and not contain =)
is_kv() {
  local kv="$1"
  [[ "$kv" == *=* ]] && [[ -n "${kv%%=*}" ]]
}

run_task() {
  local task_name="$1"; shift
  local base_url="$1"; shift

  # Collect any additional KEY=VALUE envs passed after the task name
  local -a raw_envs=()
  if (($# > 0)); then
    raw_envs=("$@")
  fi

  # Sanitize env list: drop empty entries, trim, require KEY=VALUE
  local -a envs=()
  for ent in "${raw_envs[@]:-}"; do
    local t
    t="$(trim "$ent")"
    [[ -z "$t" ]] && continue
    if is_kv "$t"; then
      envs+=("$t")
    else
      echo "[$(ts)] Skipping invalid env (not KEY=VALUE): '$ent'"
    fi
  done

  print_hdr "Starting task: ${task_name}"

  # Build docker args
  local -a docker_args=(run --rm)
  [[ -n "${ADD_HOST_FLAG:-}" ]] && docker_args+=("$ADD_HOST_FLAG")

  local -a docker_env_flags=(-e "TASK=${task_name}" -e "BASE_URL=${base_url}")
  for kv in "${envs[@]:-}"; do
    # Guard again against empty kv just in case
    [[ -n "$kv" ]] && docker_env_flags+=(-e "$kv")
  done

  echo "[$(ts)] Using DOCKER_IMAGE=${DOCKER_IMAGE}"
  echo "[$(ts)] Using BASE_URL=${base_url}"
  if ((${#envs[@]:-0})); then
    echo "[$(ts)] Extra env: ${envs[*]}"
  fi

  docker "${docker_args[@]}" "${docker_env_flags[@]}" "${DOCKER_IMAGE}"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "[$(ts)] ✅ Completed task: ${task_name} (exit code 0)"
  else
    echo "[$(ts)] ❌ Completed task: ${task_name} with errors (exit code ${rc})"
  fi
  return $rc
}

# -----------------------------
# Main
# -----------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <task_name> [KEY=VALUE ...]"
  echo "Examples:"
  echo "  $0 get_motels PAGE_SIZE=25 CHAIN_LOOKUP=true"
  echo "  BASE_URL_MOTEL=http://host.docker.internal:8085 $0 seed_motel_rooms FLOOR_END=5"
  exit 1
fi

TASK_NAME="$1"; shift

# Choose BASE_URL by task group
case "$TASK_NAME" in
  post_motel_chain|ping_once|get_motel_chains|get_motels|seed_room_categories|seed_motel_rooms)
    BASE_URL_TO_USE="$BASE_URL_MOTEL"
    ;;
  reservation_* )
    BASE_URL_TO_USE="$BASE_URL_RESV"
    ;;
  *)
    echo "Unknown task: $TASK_NAME"
    echo "Valid motel tasks: post_motel_chain, ping_once, get_motel_chains, get_motels, seed_room_categories, seed_motel_rooms"
    echo "Valid reservation tasks: reservation_ping_once, reservation_all_motels, reservation_from_availability, reservation_all_bookings, reservation_by_ids"
    exit 2
    ;;
esac

# Pass remaining args as envs (will be sanitized)
run_task "$TASK_NAME" "$BASE_URL_TO_USE" "$@"
