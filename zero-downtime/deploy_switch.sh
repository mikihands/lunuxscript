#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------
# Config - Modify these paths for your environment
# -----------------------------------------------------------
# Path to your docker-compose file
COMPOSE_FILE="$HOME/app/docker-compose.prod.yml"
# Script that handles Nginx upstream switching
SWITCH_SCRIPT="$HOME/scripts/switch_app.sh"

# Service names defined in your docker-compose.yml
SVC_WEB="web-app"
SVC_WORKER="celery-worker"
SVC_BEAT="celery-beat"

# Port mapping based on your Nginx upstream config
PORT_BLUE="18001"
PORT_GREEN="18002"

# Health check settings
WAIT_SECONDS=15           # Initial wait for service startup
HEALTH_TIMEOUT=2          # Curl timeout (seconds)
HEALTH_RETRY=10           # Max retries

# Terminal Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# -----------------------------------------------------------
# Helpers
# -----------------------------------------------------------
log()  { echo -e "${BLUE}[$(date '+%F %T')]${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*"; }

usage() {
  echo -e "${RED}Usage: $0 [blue|green]${NC}"
  exit 1
}

dc() {
  # Docker Compose wrapper with project isolation (-p)
  docker compose -f "$COMPOSE_FILE" "$@"
}

health_check() {
  local port="$1"
  local url="http://127.0.0.1:${port}/health/" # Adjust health check endpoint

  log "Health checking: ${url}"
  for i in $(seq 1 "$HEALTH_RETRY"); do
    if curl -fsSIL --max-time "$HEALTH_TIMEOUT" "$url" >/dev/null 2>&1; then
      ok "Health check passed (port=${port})"
      return 0
    fi
    warn "No response yet (Attempt ${i}/${HEALTH_RETRY})"
    sleep 1
  done

  err "Health check failed (port=${port})"
  return 1
}

require_files() {
  if [ ! -f "$COMPOSE_FILE" ]; then
    err "Compose file not found: $COMPOSE_FILE"
    exit 1
  fi
  if [ ! -x "$SWITCH_SCRIPT" ]; then
    err "Switch script not found or not executable: $SWITCH_SCRIPT"
    err "Run: chmod +x $SWITCH_SCRIPT"
    exit 1
  fi
}

# -----------------------------------------------------------
# Main Logic
# -----------------------------------------------------------
if [ "${1:-}" != "blue" ] && [ "${1:-}" != "green" ]; then
  usage
fi

TARGET="$1"
if [ "$TARGET" == "blue" ]; then
  OTHER="green"
  PORT_TARGET="$PORT_BLUE"
else
  OTHER="blue"
  PORT_TARGET="$PORT_GREEN"
fi

require_files

log "Deployment Target: ${TARGET} (port=${PORT_TARGET})"
log "Stopping background services (Celery) in the current ${OTHER} environment..."

# 1) Stop Celery in the 'OTHER' environment to free up CPU resources
set +e
dc -p "${OTHER}-app" stop "$SVC_WORKER" "$SVC_BEAT" >/dev/null 2>&1
STOP_RC=$?
set -e

if [ $STOP_RC -eq 0 ]; then
  ok "${OTHER} environment: ${SVC_WORKER}, ${SVC_BEAT} stopped"
else
  warn "Failed to stop services in ${OTHER} (might not be running). Proceeding..."
fi

# 2) Spin up Web for the TARGET environment
log "Starting ${TARGET} environment: ${SVC_WEB}..."
dc -p "${TARGET}-app" up -d "$SVC_WEB"
ok "${TARGET} environment: web startup requested"

# 3) Wait for initialization
log "Waiting ${WAIT_SECONDS}s for application initialization..."
sleep "$WAIT_SECONDS"

# 4) Health check
if ! health_check "$PORT_TARGET"; then
  err "Deployment aborted: ${TARGET} web is not responding."
  log "Recovering ${OTHER} background services..."
  dc -p "${OTHER}-app" up -d "$SVC_WORKER" "$SVC_BEAT" || warn "Recovery failed (Manual check required)"
  err "Check logs: docker compose -f \"$COMPOSE_FILE\" -p ${TARGET}-app logs -n 200 ${SVC_WEB}"
  exit 1
fi

# 5) Switch Nginx Upstream
log "Switching Nginx upstream to ${TARGET}: ${SWITCH_SCRIPT} ${TARGET}"
if "$SWITCH_SCRIPT" "$TARGET"; then
  ok "Nginx switch completed (${TARGET})"
else
  err "Nginx switch failed. Aborting deployment."
  log "Recovering ${OTHER} background services..."
  dc -p "${OTHER}-app" up -d "$SVC_WORKER" "$SVC_BEAT" || warn "Recovery failed (Manual check required)"
  exit 1
fi

# 6) Start Celery for the TARGET environment
log "Starting background services for ${TARGET} environment..."
dc -p "${TARGET}-app" up -d "$SVC_WORKER" "$SVC_BEAT"
ok "Deployment Successful 🎉 (Active: ${TARGET})"

# Final Instruction for Manual Cleanup
warn "--------------------------------------------------------"
warn "NOTICE: The ${OTHER} environment is still running."
warn "1. Please verify the service in your browser manually."
warn "2. If everything is fine, clean up the old environment:"
echo -e "${GREEN}   docker compose -f \"$COMPOSE_FILE\" -p ${OTHER}-app down${NC}"
warn "--------------------------------------------------------"

exit 0
