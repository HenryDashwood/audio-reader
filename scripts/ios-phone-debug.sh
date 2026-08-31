#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_dir="$repo_root/backend"
runtime_dir="$repo_root/build/phone-debug"
pid_file="$runtime_dir/backend.pid"
log_file="$runtime_dir/backend.log"
health_url="http://127.0.0.1:8000/health"
development_token="hearful-local-development"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required tool '$1' is not installed" >&2
    exit 1
  fi
}

backend_is_healthy() {
  curl --fail --silent --max-time 2 "$health_url" >/dev/null 2>&1
}

backend_accepts_development_auth() {
  curl --fail --silent --max-time 2 \
    --header "Authorization: Bearer $development_token" \
    "http://127.0.0.1:8000/me" >/dev/null 2>&1
}

managed_backend_pid() {
  local pid command
  [[ -f "$pid_file" ]] || return 1
  pid="$(<"$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *"uvicorn audioreader.main:app"* ]] || return 1
  printf '%s\n' "$pid"
}

stop_backend() {
  local pid
  if ! pid="$(managed_backend_pid)"; then
    rm -f "$pid_file"
    echo "The managed phone-debug backend is not running."
    return
  fi

  kill "$pid"
  for _ in {1..40}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  rm -f "$pid_file"
  echo "Stopped the phone-debug backend."
}

stop_stale_magpie_backends() {
  local pid command stopped=0
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *"uvicorn audioreader.main:app"* ]] || continue
    echo "Stopping stale Magpie backend process $pid"
    kill "$pid"
    stopped=1
  done < <(lsof -tiTCP:8000 2>/dev/null | sort -u || true)

  if [[ "$stopped" == "1" ]]; then
    for _ in {1..40}; do
      lsof -tiTCP:8000 2>/dev/null \
        | while read -r pid; do
          command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
          [[ "$command" == *"uvicorn audioreader.main:app"* ]] && printf '%s\n' "$pid"
        done \
        | grep -q . || return
      sleep 0.1
    done
  fi
}

start_database() {
  local published_port
  echo "Starting the local database"
  docker compose -f "$repo_root/docker-compose.yml" up -d db
  published_port="$(
    docker compose -f "$repo_root/docker-compose.yml" port db 5432 2>/dev/null || true
  )"
  if [[ "$published_port" != *:* || "$published_port" == *":0" ]]; then
    echo "Repairing the database container's missing host port"
    docker compose -f "$repo_root/docker-compose.yml" up -d --force-recreate db
  fi

  for _ in {1..40}; do
    if docker compose -f "$repo_root/docker-compose.yml" exec -T db \
      pg_isready -U audioreader -d audioreader >/dev/null 2>&1
    then
      return
    fi
    sleep 0.25
  done

  echo "error: PostgreSQL did not become ready" >&2
  exit 1
}

start_backend() {
  local pid managed_pid=""
  if backend_is_healthy; then
    if backend_accepts_development_auth; then
      echo "Local backend is already healthy"
      return
    fi
    managed_pid="$(managed_backend_pid || true)"
    if [[ -z "$managed_pid" ]]; then
      echo "error: port 8000 belongs to a backend without phone-debug authentication" >&2
      echo "Stop that process, then run 'make ios-phone-debug' again." >&2
      exit 1
    fi
  fi

  if [[ -n "$managed_pid" ]]; then
    pid="$managed_pid"
  elif pid="$(managed_backend_pid)"; then
    :
  else
    pid=""
  fi
  if [[ -n "$pid" ]]; then
    echo "Restarting an unhealthy managed backend"
    kill "$pid"
    for _ in {1..40}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi

  stop_stale_magpie_backends
  rm -f "$pid_file"

  mkdir -p "$runtime_dir"
  echo "Starting the local backend (log: $log_file)"
  (
    cd "$backend_dir"
    nohup env \
      AUDIOREADER_ENVIRONMENT=development \
      AUDIOREADER_DEVELOPMENT_AUTH_TOKEN="$development_token" \
      AUDIOREADER_POLL_INTERVAL_SECONDS=0 \
      uv run uvicorn audioreader.main:app --reload --host 0.0.0.0 --port 8000 \
      >"$log_file" 2>&1 </dev/null &
    echo "$!" >"$pid_file"
  )

  for _ in {1..80}; do
    if backend_is_healthy && backend_accepts_development_auth; then
      echo "Local backend is ready"
      return
    fi
    sleep 0.25
  done

  echo "error: the local backend did not become healthy" >&2
  tail -n 30 "$log_file" >&2 || true
  rm -f "$pid_file"
  exit 1
}

action="${1:-run}"
if [[ "$action" == "stop" ]]; then
  stop_backend
  exit 0
fi
if [[ "$action" != "run" && "$action" != "backend" ]]; then
  echo "Usage: $0 [run|backend|stop]" >&2
  exit 2
fi

require curl
require docker
require lsof
require uv

if [[ "${IOS_DEVICE_DRY_RUN:-0}" == "1" ]]; then
  exec "$repo_root/scripts/ios-dev.sh" device-local
fi

mkdir -p "$runtime_dir"
start_database
(
  cd "$backend_dir"
  uv run alembic upgrade head
)
start_backend

if [[ "$action" == "backend" ]]; then
  exit 0
fi

exec "$repo_root/scripts/ios-dev.sh" device-local
