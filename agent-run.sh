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

# ---- State-dir layout on the configs surface (r6) -----------------------------

# OPENCLAW_STATE_DIR is the configs surface itself (see entrypoint.sh r6
# note): state-dir entries are real files/dirs there. Everything in this
# section runs as AGENT_UID — under a root_squash export the container's
# root cannot write to the surface. Idempotent on every start.
STATE_DIR="${AGENT_HOME}/configs/main"
mkdir -p "${STATE_DIR}/state" "${STATE_DIR}/credentials" "${STATE_DIR}/npm"

# exec-approvals.json is deliberately NOT seeded: with no symlink in its
# path the runtime creates and maintains its own file (its refusal was
# symlink-specific), and seeding a guessed schema risks breaking approvals
# a second way.

# Entries that belong on OTHER surfaces stay symlinks — now living on the
# configs surface, so they persist across recreates. logs/ intentionally
# points at container-local /tmp: docker logs is the diagnostic surface, and
# gateway log chatter doesn't belong on NFS (nor secrets-in-logs on a share
# that outlives the container).
ensure_link() {
  local link="$1" target="$2"
  if [ -d "${link}" ] && [ ! -L "${link}" ]; then
    # A real dir (runtime-created before this boot placed the symlink):
    # preserve its contents on the link's target, then replace it.
    if [ -n "$(ls -A "${link}" 2>/dev/null)" ]; then
      log "relocating ${link} contents to ${target} (one-time)"
      mkdir -p "${target}"
      (shopt -s dotglob; mv "${link}"/* "${target}/") \
        || die 4 "relocation failed: ${link} -> ${target}"
    fi
    rmdir "${link}"
  fi
  ln -sfn "${target}" "${link}"
}

mkdir -p "${AGENT_HOME}/memory/main/workspace" \
         "${AGENT_HOME}/memory/main/openclaw_memory" \
         /tmp/openclaw-logs
ensure_link "${STATE_DIR}/workspace" "${AGENT_HOME}/memory/main/workspace"
ensure_link "${STATE_DIR}/memory"    "${AGENT_HOME}/memory/main/openclaw_memory"
ensure_link "${STATE_DIR}/scratch"   "${AGENT_HOME}/scratch/main"
ensure_link "${STATE_DIR}/logs"      /tmp/openclaw-logs

# ---- Per-agent session relocation (r5) ----------------------------------------

# agents/ is a real dir in the state dir (configs surface) — the secrets-safe
# home for the per-agent tree (agents/<id>/agent/ holds the auth store). The
# episodic record, agents/<id>/sessions/, belongs on the sessions surface
# instead: symlink each id's sessions/ leaf to
# ${AGENT_HOME}/sessions/<id>/sessions. Leaf symlinks live ON the configs
# surface, so they persist across recreates.
#
# A sub-agent created mid-run writes sessions into a REAL directory here
# (still persistent — configs surface) until the next boot places its leaf
# symlink; ensure_link moves the contents across to the sessions surface
# first. The legacy ${STATE_DIR}/sessions path must never exist, or the
# runtime replays its legacy migration on every recreate.
AGENTS_DIR="${STATE_DIR}/agents"
mkdir -p "${AGENTS_DIR}/main"

for agent_dir in "${AGENTS_DIR}"/*/; do
  [ -d "${agent_dir}" ] || continue
  id="$(basename "${agent_dir}")"
  mkdir -p "${AGENT_HOME}/sessions/${id}/sessions"
  ensure_link "${AGENTS_DIR}/${id}/sessions" "${AGENT_HOME}/sessions/${id}/sessions"
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
