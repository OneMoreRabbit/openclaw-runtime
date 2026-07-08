#!/usr/bin/env bash
# openclaw-runtime — AGENT PHASE.
#
# Runs as AGENT_UID, gosu'd from entrypoint.sh. Everything here reads the
# NFS-backed, agent-owned surface mounts (openclaw.json mode 0600, secrets.env
# mode 0600), so it must run as the agent user — under a root_squash NFS
# export the container's root is squashed to `nobody` and cannot read them.
#
# Exit codes (continued from entrypoint.sh):
#   4 = missing or empty surface mount
#   5 = missing or invalid openclaw.json
#   7 = secrets file present but unreadable
#  >7 = upstream openclaw exit code

set -euo pipefail

log() { printf '[agent-run] %s\n' "$*" >&2; }
die() { local code="$1"; shift; log "ERROR ($code): $*"; exit "$code"; }

AGENT_HOME="${AGENT_HOME:?AGENT_HOME not set}"
OPENCLAW_BIND="${OPENCLAW_BIND:-lan}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_EXTRA_ARGS="${OPENCLAW_EXTRA_ARGS:-}"

# ---- Validate surface mounts ------------------------------------------------

for surface in configs memory sessions scratch; do
  mnt="${AGENT_HOME}/${surface}/main"
  if [ ! -d "${mnt}" ]; then
    die 4 "surface mount missing: ${mnt}"
  fi
done

# ---- Ensure relocation targets exist (r4) ------------------------------------

# Targets of the state/credentials (r4) and plugin-root (r6) symlinks created
# in the root phase. Must be created here, as AGENT_UID: under a root_squash
# export the container's root cannot mkdir on the surface. Idempotent on
# every start.
mkdir -p "${AGENT_HOME}/configs/main/state" \
         "${AGENT_HOME}/configs/main/credentials" \
         "${AGENT_HOME}/configs/main/npm"

# ---- Per-agent session relocation (r5) ----------------------------------------

# ~/.openclaw/agents is symlinked (root phase) to configs/main/agents — the
# secrets-safe home for the per-agent tree (agents/<id>/agent/ holds the auth
# store). The episodic record, agents/<id>/sessions/, belongs on the sessions
# surface instead: symlink each id's sessions/ leaf to
# ${AGENT_HOME}/sessions/<id>/sessions. Leaf symlinks live ON the configs
# surface, so they persist across recreates; ln -sfn keeps this idempotent.
#
# A sub-agent created mid-run writes sessions into a REAL directory here
# (still persistent — configs surface) until the next boot places its leaf
# symlink; that boot moves the contents across to the sessions surface first.
AGENTS_DIR="${AGENT_HOME}/configs/main/agents"
mkdir -p "${AGENTS_DIR}/main"

relocate_sessions_leaf() {
  local id="$1"
  local leaf="${AGENTS_DIR}/${id}/sessions"
  local target="${AGENT_HOME}/sessions/${id}/sessions"
  mkdir -p "${target}"
  if [ -d "${leaf}" ] && [ ! -L "${leaf}" ]; then
    if [ -n "$(ls -A "${leaf}" 2>/dev/null)" ]; then
      log "relocating ${leaf} contents to ${target} (one-time, cross-surface)"
      (shopt -s dotglob; mv "${leaf}"/* "${target}/") \
        || die 4 "session leaf relocation failed for agent id '${id}'"
    fi
    rmdir "${leaf}"
  fi
  ln -sfn "${target}" "${leaf}"
}

for agent_dir in "${AGENTS_DIR}"/*/; do
  [ -d "${agent_dir}" ] || continue
  relocate_sessions_leaf "$(basename "${agent_dir}")"
done

# ---- Validate openclaw.json -------------------------------------------------

CONF_FILE="${AGENT_HOME}/configs/main/openclaw.json"
if [ ! -r "${CONF_FILE}" ]; then
  die 5 "openclaw.json missing or unreadable at ${CONF_FILE}"
fi

# ---- Source secrets ---------------------------------------------------------

SECRETS_FILE="${AGENT_HOME}/configs/main/secrets.env"
if [ -e "${SECRETS_FILE}" ]; then
  if [ ! -r "${SECRETS_FILE}" ]; then
    die 7 "secrets.env present but unreadable"
  fi
  set -a
  # shellcheck disable=SC1090
  . "${SECRETS_FILE}"
  set +a
fi

# ---- Exec openclaw ----------------------------------------------------------

log "starting openclaw gateway: bind=${OPENCLAW_BIND} port=${OPENCLAW_PORT}"

# shellcheck disable=SC2086
exec openclaw gateway run --bind "${OPENCLAW_BIND}" --port "${OPENCLAW_PORT}" ${OPENCLAW_EXTRA_ARGS}
