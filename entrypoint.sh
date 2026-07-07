#!/usr/bin/env bash
# openclaw-runtime entrypoint — ROOT PHASE.
#
# Runs as root: validate environment, provision the in-container agent
# identity, create the path-relocation symlinks, then drop privileges and
# hand off to agent-run.sh for everything that touches the surface mounts.
#
# Why the split (wrapper rev r3): the four surface mounts are bind-mounted
# host paths that resolve through to NFS. Under a root_squash export the
# container's root is squashed to `nobody` and cannot read agent-owned 0600
# files (openclaw.json, secrets.env) on those surfaces. So mount/config
# validation and secrets sourcing must run AFTER the privilege drop, as
# AGENT_UID. Only identity provisioning and the container-local symlink
# relocation genuinely need root — they stay here.
#
# Exit codes (kept in sync with the openclaw-image-architecture doc):
#   3 = missing required env var      (this script)
#   6 = identity provisioning failed  (this script)
#   4 = missing or empty surface mount   (agent-run.sh)
#   5 = missing or invalid openclaw.json (agent-run.sh)
#   7 = secrets file present but unreadable (agent-run.sh)
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

# ---- 2. Provision in-container agent identity -------------------------------

# Create group(s) and the agent user with the host-side IDs.
# If a group/user with that ID already exists, reuse it.

if ! getent group "${AGENT_PRIMARY_GID}" >/dev/null; then
  groupadd -g "${AGENT_PRIMARY_GID}" agent || die 6 "groupadd failed"
fi

if ! getent passwd "${AGENT_UID}" >/dev/null; then
  useradd -u "${AGENT_UID}" -g "${AGENT_PRIMARY_GID}" -d /home/agent -s /usr/sbin/nologin -M agent \
    || die 6 "useradd failed"
else
  # AGENT_UID collides with an account already in the base image (e.g. `node`
  # at 1000, `nobody` at 65534). useradd is skipped, so no /home/agent home is
  # registered for this uid. State discovery still works because we export
  # OPENCLAW_STATE_DIR below — but supplementary-group attachment may target
  # the wrong account. Warn loudly; don't block (the probe legitimately runs
  # as the operator's own uid, which can collide).
  existing="$(getent passwd "${AGENT_UID}" | cut -d: -f1,6)"
  log "WARNING: AGENT_UID ${AGENT_UID} matches pre-existing account '${existing%%:*}'" \
      "(home '${existing##*:}'); identity provisioning skipped." \
      "State discovery handled by OPENCLAW_STATE_DIR; supplementary groups may not apply."
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

# ---- 3. Path relocation symlinks --------------------------------------------

# Creating a symlink does not read its target, so this is safe as root even
# though the targets live on the (root-squashed) surface mounts.

HOME_OC="/home/agent/.openclaw"
mkdir -p "${HOME_OC}"

ln -sfn "${AGENT_HOME}/configs/main/openclaw.json"       "${HOME_OC}/openclaw.json"
ln -sfn "${AGENT_HOME}/configs/main/exec-approvals.json" "${HOME_OC}/exec-approvals.json"
ln -sfn "${AGENT_HOME}/memory/main/workspace"            "${HOME_OC}/workspace"
ln -sfn "${AGENT_HOME}/memory/main/openclaw_memory"      "${HOME_OC}/memory"
ln -sfn "${AGENT_HOME}/sessions/main"                    "${HOME_OC}/sessions"
ln -sfn "${AGENT_HOME}/scratch/main"                     "${HOME_OC}/scratch"

# r4: openclaw also writes ~/.openclaw/state/ (sqlite runtime state, upstream
# 2026.6.x+) and ~/.openclaw/credentials/ (channel auth — e.g. the WhatsApp
# Baileys pairing session). Unrelocated, both die with the container on every
# recreate — re-pairing WhatsApp each deploy. They are secret-bearing runtime
# state, so they live on the configs surface (0700, never synced, never
# ingested) beside exec-approvals.json.
ln -sfn "${AGENT_HOME}/configs/main/state"               "${HOME_OC}/state"
ln -sfn "${AGENT_HOME}/configs/main/credentials"         "${HOME_OC}/credentials"

chown -h "${AGENT_UID}:${AGENT_PRIMARY_GID}" "${HOME_OC}"/* || true
chown    "${AGENT_UID}:${AGENT_PRIMARY_GID}" "${HOME_OC}"   || true

# Pin openclaw's state directory explicitly. Without this, openclaw derives
# its state root from $HOME, which gosu sets from the agent uid's passwd entry
# — and if AGENT_UID collides with a pre-existing account (no /home/agent home
# registered) openclaw looks in the wrong place and exits 78 "Missing config".
# OPENCLAW_STATE_DIR makes discovery independent of uid, $HOME, and gosu.
# Exported so it survives the gosu hand-off to agent-run.sh.
export OPENCLAW_STATE_DIR="${HOME_OC}"

# ---- 4. Drop privileges; hand off to the agent phase ------------------------

log "dropping to uid=${AGENT_UID} gid=${AGENT_PRIMARY_GID}; handing off to agent-run.sh"

exec gosu "${AGENT_UID}:${AGENT_PRIMARY_GID}" /opt/wrapper/agent-run.sh
