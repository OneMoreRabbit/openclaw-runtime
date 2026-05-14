#!/usr/bin/env bash
# openclaw-runtime entrypoint.
# Runs as root (briefly): preflight, identity provisioning, symlink relocation,
# secrets sourcing, then drops to the agent user and execs openclaw.
#
# Exit codes (must stay in sync with integrations/openclaw-image-architecture-v0_2.md):
#   3 = missing required env var
#   4 = missing or empty surface mount
#   5 = missing or invalid openclaw.json
#   6 = identity provisioning failed
#   7 = secrets file present but unreadable
#  >7 = upstream openclaw exit code

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { local code="$1"; shift; log "ERROR ($code): $*"; exit "$code"; }

# ---- 1. Validate environment ------------------------------------------------

: "${AGENT_NAME:?missing AGENT_NAME}" 2>/dev/null || die 3 "AGENT_NAME not set"
: "${AGENT_UID:?missing AGENT_UID}"   2>/dev/null || die 3 "AGENT_UID not set"
: "${AGENT_PRIMARY_GID:?}"            2>/dev/null || die 3 "AGENT_PRIMARY_GID not set"
: "${AGENT_HOME:?}"                   2>/dev/null || die 3 "AGENT_HOME not set"

# AGENT_SUPP_GIDS may be empty; the variable must exist.
AGENT_SUPP_GIDS="${AGENT_SUPP_GIDS-}"

OPENCLAW_BIND="${OPENCLAW_BIND:-lan}"
OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_EXTRA_ARGS="${OPENCLAW_EXTRA_ARGS:-}"

# ---- 2. Validate surface mounts --------------------------------------------

for surface in configs memory sessions scratch; do
  mnt="${AGENT_HOME}/${surface}/main"
  if [ ! -d "${mnt}" ]; then
    die 4 "surface mount missing: ${mnt}"
  fi
done

# ---- 3. Validate openclaw.json ---------------------------------------------

CONF_FILE="${AGENT_HOME}/configs/main/openclaw.json"
if [ ! -r "${CONF_FILE}" ]; then
  die 5 "openclaw.json missing or unreadable at ${CONF_FILE}"
fi

# ---- 4. Provision in-container agent identity -------------------------------

# Create group(s) and the agent user with the host-side IDs.
# If a group/user with that ID already exists, reuse it.

if ! getent group "${AGENT_PRIMARY_GID}" >/dev/null; then
  groupadd -g "${AGENT_PRIMARY_GID}" agent || die 6 "groupadd failed"
fi

if ! getent passwd "${AGENT_UID}" >/dev/null; then
  useradd -u "${AGENT_UID}" -g "${AGENT_PRIMARY_GID}" -d /home/agent -s /usr/sbin/nologin -M agent \
    || die 6 "useradd failed"
fi

if [ -n "${AGENT_SUPP_GIDS}" ]; then
  IFS=',' read -ra SUPP_GIDS <<< "${AGENT_SUPP_GIDS}"
  for gid in "${SUPP_GIDS[@]}"; do
    [ -z "${gid}" ] && continue
    if ! getent group "${gid}" >/dev/null; then
      groupadd -g "${gid}" "supp_${gid}" || die 6 "supp group ${gid} create failed"
    fi
  done
  # Re-resolve the agent user's groups
  USERMOD_GROUPS=$(IFS=,; echo "${SUPP_GIDS[*]}")
  usermod -G "${USERMOD_GROUPS}" "$(getent passwd "${AGENT_UID}" | cut -d: -f1)" \
    || die 6 "usermod supp groups failed"
fi

chown -R "${AGENT_UID}:${AGENT_PRIMARY_GID}" /home/agent

# ---- 5. Path relocation symlinks --------------------------------------------

HOME_OC="/home/agent/.openclaw"
mkdir -p "${HOME_OC}"

ln -sfn "${AGENT_HOME}/configs/main/openclaw.json"       "${HOME_OC}/openclaw.json"
ln -sfn "${AGENT_HOME}/configs/main/exec-approvals.json" "${HOME_OC}/exec-approvals.json"
ln -sfn "${AGENT_HOME}/memory/main/workspace"            "${HOME_OC}/workspace"
ln -sfn "${AGENT_HOME}/memory/main/openclaw_memory"      "${HOME_OC}/memory"
ln -sfn "${AGENT_HOME}/sessions/main"                    "${HOME_OC}/sessions"
ln -sfn "${AGENT_HOME}/scratch/main"                     "${HOME_OC}/scratch"

chown -h "${AGENT_UID}:${AGENT_PRIMARY_GID}" "${HOME_OC}"/* || true
chown    "${AGENT_UID}:${AGENT_PRIMARY_GID}" "${HOME_OC}"   || true

# ---- 6. Source secrets ------------------------------------------------------

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

# ---- 7. Drop privileges and exec --------------------------------------------

log "starting openclaw gateway as uid=${AGENT_UID} gid=${AGENT_PRIMARY_GID} bind=${OPENCLAW_BIND} port=${OPENCLAW_PORT}"

# shellcheck disable=SC2086
exec gosu "${AGENT_UID}:${AGENT_PRIMARY_GID}" \
  openclaw gateway run --bind "${OPENCLAW_BIND}" --port "${OPENCLAW_PORT}" ${OPENCLAW_EXTRA_ARGS}
