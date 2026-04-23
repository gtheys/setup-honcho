#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Honcho — Single-Script Local Setup (Arch Linux)
# =============================================================================
# Docker containers: PostgreSQL 15 + pgvector (persistent named volume) + Redis
# Native processes:  Honcho API + Deriver (via uv)
#
# Usage:
#   ./deploy.sh up          # start everything
#   ./deploy.sh down        # stop everything gracefully
#   ./deploy.sh status      # check what's running
#   ./deploy.sh logs        # tail API + deriver logs
#   ./deploy.sh psql        # connect to the database
#   ./deploy.sh nuke        # stop + delete ALL data (DB included)
#
# Env overrides:
#   HONCHO_HOME=~/honcho        where the repo lives
#   HONCHO_PG_PORT=5432         postgres host port
#   HONCHO_REDIS_PORT=6379      redis host port
#   HONCHO_API_PORT=8000        api host port
# =============================================================================

HONCHO_DIR="${HONCHO_HOME:-$HOME/honcho}"
DATA_DIR="${HONCHO_DIR}/.honcho-local"
PID_DIR="${DATA_DIR}/pids"
LOG_DIR="${DATA_DIR}/logs"
PG_PORT="${HONCHO_PG_PORT:-5433}"
REDIS_PORT="${HONCHO_REDIS_PORT:-6380}"
API_PORT="${HONCHO_API_PORT:-8000}"
PG_CONTAINER="honcho-postgres"
REDIS_CONTAINER="honcho-redis"
PG_VOLUME="honcho-pgdata"

# Use local Docker socket, not whatever DOCKER_HOST points to (e.g. Minikube)
export DOCKER_HOST="unix:///var/run/docker.sock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'
info() { echo -e "${CYAN}[·]${NC} $*"; }
ok() { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() {
  echo -e "${RED}[✗]${NC} $*"
  exit 1
}

# =============================================================================
# Helpers
# =============================================================================
check_deps() {
  local missing=()
  for cmd in docker git; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] && err "Missing: ${missing[*]}. Install with: sudo pacman -S ${missing[*]}"

  docker info >/dev/null 2>&1 || err "Docker daemon not running. Start it: sudo systemctl start docker"

  if ! command -v uv >/dev/null 2>&1; then
    info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    ok "uv installed."
  fi
}

ensure_repo() {
  if [[ -d "${HONCHO_DIR}/.git" ]]; then
    info "Honcho repo exists at ${HONCHO_DIR}, pulling latest..."
    git -C "${HONCHO_DIR}" pull --ff-only 2>/dev/null || warn "Pull failed — using existing code."
  else
    info "Cloning Honcho into ${HONCHO_DIR}..."
    git clone --depth 1 https://github.com/plastic-labs/honcho.git "${HONCHO_DIR}"
  fi
  ok "Honcho source ready."
}

ensure_deps() {
  info "Syncing Python dependencies..."
  cd "${HONCHO_DIR}"
  uv sync --quiet
  ok "Dependencies installed."
}

# Apply patches for known upstream bugs that haven't been fixed yet.
# Each patch is idempotent — safe to re-run on every `up`.
apply_patches() {
  local backend="${HONCHO_DIR}/src/llm/backends/anthropic.py"

  # Patch: Anthropic rejects stop sequences that are purely whitespace (e.g. "   \n"
  # passed by the deriver). Filter them out before the API call.
  # Upstream issue: deriver.py line ~130 passes ["   \n", "\n\n\n\n"] as stop_sequences.
  local sentinel="valid_stop = [s for s in stop if s.strip()]"
  if grep -qF "$sentinel" "$backend" 2>/dev/null; then
    ok "Patch (whitespace stop_sequences) already applied."
  else
    info "Applying patch: filter whitespace stop_sequences for Anthropic backend..."
    python3 -c "
import sys
path = sys.argv[1]
content = open(path).read()
old = '        if stop:\n            params[\"stop_sequences\"] = stop'
new = (
    '        if stop:\n'
    '            # AIDEV-NOTE: Anthropic rejects purely-whitespace stop sequences\n'
    '            # (e.g. \"   \\\\n\" from the deriver). Patched by deploy.sh.\n'
    '            valid_stop = [s for s in stop if s.strip()]\n'
    '            if valid_stop:\n'
    '                params[\"stop_sequences\"] = valid_stop'
)
patched = content.replace(old, new)
if patched == content:
    print('WARNING: patch target not found in ' + path + ' — Honcho may have changed upstream')
    sys.exit(1)
open(path, 'w').write(patched)
" "$backend"
    ok "Patch (whitespace stop_sequences) applied."
  fi
}

ensure_env() {
  local env_file="${HONCHO_DIR}/.env"
  if [[ -f "$env_file" ]]; then
    ok ".env already exists — reusing."
    return
  fi

  info "Creating .env — need your API keys."
  echo ""

  local anthropic_key="${LLM_ANTHROPIC_API_KEY:-}"
  if [[ -z "$anthropic_key" ]]; then
    read -rsp "$(echo -e "${YELLOW}Anthropic API Key (required):${NC} ")" anthropic_key
    echo
    [[ -z "$anthropic_key" ]] && err "Anthropic key is required."
  fi

  local gemini_key="${LLM_GEMINI_API_KEY-__unset__}"
  local groq_key="${LLM_GROQ_API_KEY-__unset__}"
  local openai_key="${LLM_OPENAI_API_KEY-__unset__}"

  if [[ "$gemini_key" == "__unset__" ]]; then
    read -rsp "$(echo -e "${YELLOW}Gemini API Key    ${DIM}(Enter to skip):${NC} ")" gemini_key; echo
  else
    info "Gemini API Key    — using env var."
    [[ "$gemini_key" == "__unset__" ]] && gemini_key=""
  fi
  if [[ "$groq_key" == "__unset__" ]]; then
    read -rsp "$(echo -e "${YELLOW}Groq API Key      ${DIM}(Enter to skip):${NC} ")" groq_key; echo
  else
    info "Groq API Key      — using env var."
    [[ "$groq_key" == "__unset__" ]] && groq_key=""
  fi
  if [[ "$openai_key" == "__unset__" ]]; then
    read -rsp "$(echo -e "${YELLOW}OpenAI API Key    ${DIM}(Enter to skip):${NC} ")" openai_key; echo
  else
    info "OpenAI API Key    — using env var."
    [[ "$openai_key" == "__unset__" ]] && openai_key=""
  fi

  cat >"$env_file" <<EOF
DB_CONNECTION_URI=postgresql+psycopg://honcho:honcho@localhost:${PG_PORT}/honcho
CACHE_URL=redis://localhost:${REDIS_PORT}/0
LLM_ANTHROPIC_API_KEY=${anthropic_key}
LLM_GEMINI_API_KEY=${gemini_key}
LLM_GROQ_API_KEY=${groq_key}
LLM_OPENAI_API_KEY=${openai_key}
AUTH_USE_AUTH=false
SENTRY_ENABLED=false
LOG_LEVEL=info

# --- Model provider configuration ---
# NOTE: Honcho uses MODEL_CONFIG__TRANSPORT / MODEL_CONFIG__MODEL (pydantic-settings
# nested syntax). *_PROVIDER and *_MODEL vars are NOT recognized and will be ignored.
SUMMARY_MODEL_CONFIG__TRANSPORT=anthropic
SUMMARY_MODEL_CONFIG__MODEL=claude-haiku-4-5

DERIVER_MODEL_CONFIG__TRANSPORT=anthropic
DERIVER_MODEL_CONFIG__MODEL=claude-haiku-4-5
# Process messages immediately without waiting for 1024-token batch threshold.
# Essential for local dev — without this, short conversations are never derived.
DERIVER_FLUSH_ENABLED=true

DREAM_MODEL_CONFIG__TRANSPORT=anthropic
DREAM_MODEL_CONFIG__MODEL=claude-sonnet-4-20250514

# --- Dialectic levels (all using Anthropic) ---
# All levels must be specified together when overriding the defaults.
DIALECTIC__LEVELS__minimal__PROVIDER=anthropic
DIALECTIC__LEVELS__minimal__MODEL=claude-haiku-4-5
DIALECTIC__LEVELS__minimal__THINKING_BUDGET_TOKENS=0
DIALECTIC__LEVELS__minimal__MAX_TOOL_ITERATIONS=1
DIALECTIC__LEVELS__minimal__MAX_OUTPUT_TOKENS=250
DIALECTIC__LEVELS__minimal__TOOL_CHOICE=any

DIALECTIC__LEVELS__low__PROVIDER=anthropic
DIALECTIC__LEVELS__low__MODEL=claude-haiku-4-5
DIALECTIC__LEVELS__low__THINKING_BUDGET_TOKENS=0
DIALECTIC__LEVELS__low__MAX_TOOL_ITERATIONS=5
DIALECTIC__LEVELS__low__TOOL_CHOICE=any

DIALECTIC__LEVELS__medium__PROVIDER=anthropic
DIALECTIC__LEVELS__medium__MODEL=claude-haiku-4-5
DIALECTIC__LEVELS__medium__THINKING_BUDGET_TOKENS=1024
DIALECTIC__LEVELS__medium__MAX_TOOL_ITERATIONS=2

DIALECTIC__LEVELS__high__PROVIDER=anthropic
DIALECTIC__LEVELS__high__MODEL=claude-haiku-4-5
DIALECTIC__LEVELS__high__THINKING_BUDGET_TOKENS=1024
DIALECTIC__LEVELS__high__MAX_TOOL_ITERATIONS=4

DIALECTIC__LEVELS__max__PROVIDER=anthropic
DIALECTIC__LEVELS__max__MODEL=claude-haiku-4-5
DIALECTIC__LEVELS__max__THINKING_BUDGET_TOKENS=2048
DIALECTIC__LEVELS__max__MAX_TOOL_ITERATIONS=10
EOF
  ok ".env created."
}

pid_alive() {
  [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

wait_for_port() {
  local port="$1" name="$2" tries=30
  while ! ss -tlnp 2>/dev/null | grep -q ":${port} " && ((tries-- > 0)); do
    sleep 1
  done
  ((tries >= 0)) && ok "${name} is listening on port ${port}." || err "${name} failed to start on port ${port}."
}

# =============================================================================
# UP
# =============================================================================
cmd_up() {
  check_deps
  ensure_repo
  ensure_deps
  apply_patches
  ensure_env
  mkdir -p "${PID_DIR}" "${LOG_DIR}"
  cd "${HONCHO_DIR}"

  # --- PostgreSQL (persistent named volume) ---
  if docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
    ok "PostgreSQL already running."
  else
    # Remove stopped container if lingering (volume survives)
    docker rm -f "${PG_CONTAINER}" 2>/dev/null || true

    info "Starting PostgreSQL (data persists in Docker volume '${PG_VOLUME}')..."
    docker run -d \
      --name "${PG_CONTAINER}" \
      -p "${PG_PORT}:5432" \
      -e POSTGRES_DB=honcho \
      -e POSTGRES_USER=honcho \
      -e POSTGRES_PASSWORD=honcho \
      -v "${PG_VOLUME}:/var/lib/postgresql/data" \
      --health-cmd="pg_isready -U honcho -d honcho" \
      --health-interval=3s \
      --health-retries=10 \
      pgvector/pgvector:pg15 \
      postgres -c max_connections=800 \
      >/dev/null
    wait_for_port "${PG_PORT}" "PostgreSQL"
    # Give PG a moment to finish init on first run
    sleep 2
  fi

  # --- Redis ---
  if docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER}$"; then
    ok "Redis already running."
  else
    docker rm -f "${REDIS_CONTAINER}" 2>/dev/null || true
    info "Starting Redis..."
    docker run -d \
      --name "${REDIS_CONTAINER}" \
      -p "${REDIS_PORT}:6379" \
      redis:8.2 \
      >/dev/null
    wait_for_port "${REDIS_PORT}" "Redis"
  fi

  # --- Database migrations ---
  info "Running database migrations..."
  uv run alembic upgrade head 2>&1 | tail -1
  ok "Migrations done."

  # --- Honcho API ---
  if pid_alive "${PID_DIR}/api.pid"; then
    ok "Honcho API already running (PID $(cat "${PID_DIR}/api.pid"))."
  else
    info "Starting Honcho API on port ${API_PORT}..."
    nohup uv run fastapi run src/main.py --port "${API_PORT}" \
      >"${LOG_DIR}/api.log" 2>&1 &
    echo $! >"${PID_DIR}/api.pid"
    wait_for_port "${API_PORT}" "Honcho API"
  fi

  # --- Deriver ---
  if pid_alive "${PID_DIR}/deriver.pid"; then
    ok "Deriver already running (PID $(cat "${PID_DIR}/deriver.pid"))."
  else
    info "Starting Deriver worker..."
    nohup uv run python -m src.deriver \
      >"${LOG_DIR}/deriver.log" 2>&1 &
    echo $! >"${PID_DIR}/deriver.pid"
    ok "Deriver started (PID $!)."
  fi

  # --- Summary ---
  echo ""
  echo -e "${GREEN}══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Honcho is running${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  API:       http://localhost:${API_PORT}"
  echo -e "  Docs:      http://localhost:${API_PORT}/docs"
  echo -e "  Postgres:  localhost:${PG_PORT}  ${DIM}(volume: ${PG_VOLUME})${NC}"
  echo -e "  Redis:     localhost:${REDIS_PORT}"
  echo ""
  echo -e "  ${DIM}./deploy.sh down     stop everything${NC}"
  echo -e "  ${DIM}./deploy.sh logs     tail logs${NC}"
  echo -e "  ${DIM}./deploy.sh psql     connect to db${NC}"
  echo ""
}

# =============================================================================
# DOWN
# =============================================================================
cmd_down() {
  info "Stopping Honcho..."

  for svc in api deriver; do
    if pid_alive "${PID_DIR}/${svc}.pid"; then
      kill "$(cat "${PID_DIR}/${svc}.pid")" 2>/dev/null && ok "Stopped ${svc}." || warn "${svc} already gone."
      rm -f "${PID_DIR}/${svc}.pid"
    fi
  done

  for ctr in "${REDIS_CONTAINER}" "${PG_CONTAINER}"; do
    if docker ps --format '{{.Names}}' | grep -q "^${ctr}$"; then
      docker stop "${ctr}" >/dev/null && ok "Stopped ${ctr}."
    fi
  done

  echo ""
  ok "Everything stopped. Database data preserved in volume '${PG_VOLUME}'."
  echo -e "  ${DIM}./deploy.sh up    to start again (data intact)${NC}"
  echo -e "  ${DIM}./deploy.sh nuke  to delete everything including data${NC}"
}

# =============================================================================
# STATUS
# =============================================================================
cmd_status() {
  echo ""
  echo "  Service          Status"
  echo "  ───────────────  ─────────────"

  # Postgres
  if docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
    echo -e "  PostgreSQL       ${GREEN}running${NC}  :${PG_PORT}  vol=${PG_VOLUME}"
  else
    echo -e "  PostgreSQL       ${RED}stopped${NC}"
  fi

  # Redis
  if docker ps --format '{{.Names}}' | grep -q "^${REDIS_CONTAINER}$"; then
    echo -e "  Redis            ${GREEN}running${NC}  :${REDIS_PORT}"
  else
    echo -e "  Redis            ${RED}stopped${NC}"
  fi

  # API
  if pid_alive "${PID_DIR}/api.pid"; then
    echo -e "  Honcho API       ${GREEN}running${NC}  :${API_PORT}  PID=$(cat "${PID_DIR}/api.pid")"
  else
    echo -e "  Honcho API       ${RED}stopped${NC}"
  fi

  # Deriver
  if pid_alive "${PID_DIR}/deriver.pid"; then
    echo -e "  Deriver          ${GREEN}running${NC}  PID=$(cat "${PID_DIR}/deriver.pid")"
  else
    echo -e "  Deriver          ${RED}stopped${NC}"
  fi

  # Volume info
  echo ""
  local vol_size
  vol_size=$(docker volume inspect "${PG_VOLUME}" --format '{{.Mountpoint}}' 2>/dev/null) &&
    echo -e "  ${DIM}DB volume: ${vol_size}${NC}" ||
    echo -e "  ${DIM}DB volume: not yet created${NC}"
  echo ""
}

# =============================================================================
# LOGS
# =============================================================================
cmd_logs() {
  if [[ ! -d "${LOG_DIR}" ]]; then
    warn "No logs yet. Run './deploy.sh up' first."
    exit 0
  fi
  tail -f "${LOG_DIR}/api.log" "${LOG_DIR}/deriver.log"
}

# =============================================================================
# PSQL
# =============================================================================
cmd_psql() {
  docker exec -it "${PG_CONTAINER}" psql -U honcho -d honcho
}

# =============================================================================
# NUKE
# =============================================================================
cmd_nuke() {
  echo -e "${RED}This will stop everything AND delete all database data.${NC}"
  read -rp "Are you sure? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    info "Aborted."
    exit 0
  }

  cmd_down

  info "Removing containers..."
  docker rm -f "${PG_CONTAINER}" "${REDIS_CONTAINER}" 2>/dev/null || true

  info "Deleting database volume '${PG_VOLUME}'..."
  docker volume rm "${PG_VOLUME}" 2>/dev/null || true

  info "Cleaning local state..."
  rm -rf "${DATA_DIR}"

  ok "Nuked. All data gone."
}

# =============================================================================
# Main
# =============================================================================
case "${1:-help}" in
up) cmd_up ;;
down) cmd_down ;;
status) cmd_status ;;
logs) cmd_logs ;;
psql) cmd_psql ;;
nuke) cmd_nuke ;;
*)
  echo "Usage: ./deploy.sh {up|down|status|logs|psql|nuke}"
  echo ""
  echo "  up      Start Postgres, Redis, API, and Deriver"
  echo "  down    Stop everything (DB data preserved)"
  echo "  status  Show what's running"
  echo "  logs    Tail API + Deriver logs"
  echo "  psql    Open a psql shell"
  echo "  nuke    Stop + destroy all data"
  ;;
esac
