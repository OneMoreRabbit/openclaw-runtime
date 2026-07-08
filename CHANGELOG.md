# Changelog — openclaw-runtime wrapper

Wrapper revisions. The `r<rev>` suffix in an image tag (`<upstream>-r<rev>`)
bumps when the wrapper changes without the upstream OpenClaw version moving.
Images built *after* a given entry should use that entry's revision.

## r6 — 2026-07-08

**Fix: the plugin root `~/.openclaw/npm/` now persists on the configs
surface.**

2026.6.x pluginises providers and channels beyond the stock set (`brave`,
`whatsapp`, `discord` are npm-fetched via `openclaw plugins install`).
Plugin code lands under `$OPENCLAW_STATE_DIR/npm/projects/<pkg>-<hash>` —
the one state-dir writable r1–r5 did not relocate, so it was
container-ephemeral. Worse than loss: the install is *registered* in
`openclaw.json` (configs surface, persistent), so on recreate the config
references code that no longer exists and the gateway crash-loops
(`tools.web.search.provider: web_search provider is not available: brave`).

- `entrypoint.sh` (root phase): `npm → ${AGENT_HOME}/configs/main/npm`.
  Plugin code is agent-scoped runtime state, version-recorded in config,
  and secrets-adjacent (project dirs can embed tokens) → configs surface
  (0700, never synced, never ingested), consistent with
  state/credentials/agents. The symlink preserves absolute
  install/registration paths across recreates.
- `agent-run.sh` (agent phase): `mkdir -p` of the target, as `AGENT_UID`
  (root_squash rule).

The `openclaw` peerDependency symlink inside each plugin project targets
`/usr/local/lib/node_modules/openclaw` — present in every wrapper image, so
installed plugins survive image upgrades (re-install only on
upstream-compat breaks).

**Migration note:** plugins installed on r5 or earlier are gone (they were
ephemeral); if their registration lingers in `openclaw.json`, the gateway
will not start until the plugin is reinstalled once on r6 (files then land
on the surface) or the registration is removed.

**`logs/` considered and left ephemeral** (brief item 4): `docker logs` is
the diagnostic surface, the probe captures container logs on failure, and
persisting chatty log writes to NFS adds load and a potential
secrets-in-logs exposure for no operational gain. Revisit only if a debug
scenario needs post-mortem logs across recreates.

Exit codes unchanged.

## r5 — 2026-07-08

**Fix: session relocation matches the 2026.6.x per-agent layout; auth store
stays on the configs surface.**

The 2026.6.x runtime keeps a per-agent tree `~/.openclaw/agents/<id>/` and
treats a populated `~/.openclaw/sessions/` as legacy: on boot it `rename()`s
every file into `~/.openclaw/agents/main/sessions/`. Through r4 the wrapper
relocated the legacy path (`sessions → sessions surface`) but not the
per-agent tree, so the migration crossed a filesystem boundary — every
rename failed `EXDEV`, the runtime renamed the symlink aside
(`sessions.legacy-<ts>`), and new sessions were written container-ephemerally
(destroyed on recreate; each recreate replayed the failed migration).

The per-agent tree also holds **secrets**: the auth store (OAuth tokens,
API-key auth) lives at `agents/<id>/agent/openclaw-agent.sqlite`, so the tree
cannot be relocated wholesale to the (ingested, surface-group-readable)
sessions surface. The relocation splits it:

- `entrypoint.sh` (root phase): `agents → ${AGENT_HOME}/configs/main/agents`
  — the whole per-agent tree defaults to the configs surface (0700, never
  synced, never ingested). Anything the runtime adds under `agents/` in
  future is secrets-safe by default. The legacy `~/.openclaw/sessions`
  symlink is **removed** — the path must not exist, or the runtime replays
  its legacy migration on every recreate.
- `agent-run.sh` (agent phase, as `AGENT_UID`): for `main` and every id
  present under `configs/main/agents/`, symlink the episodic-record leaf
  `agents/<id>/sessions → ${AGENT_HOME}/sessions/<id>/sessions` (targets
  `mkdir -p`'d first). Leaf symlinks live on the configs surface and persist
  across recreates. A real `sessions/` dir left by a sub-agent created
  mid-run is moved across to the sessions surface before the symlink is
  placed.

Net layout: `agents/<id>/sessions/` → sessions surface (episodic record);
everything else under `agents/<id>/` (auth store, agent state) → configs
surface. `~/.openclaw/memory` is unchanged (2026.6.11 still consumes the
flat relocated store; the probe should confirm no memory writes appear under
the agents tree).

Exit codes unchanged.

## r4 — 2026-07-07

**Fix: `~/.openclaw/state/` and `~/.openclaw/credentials/` now persist.**

Upstream 2026.6.x introduced a sqlite runtime state store at
`~/.openclaw/state/openclaw.sqlite`, and channel auth has always lived at
`~/.openclaw/credentials/` (e.g. the WhatsApp Baileys pairing session, GitHub
credentials). Neither path was in the r1–r3 relocation set, so both landed in
the container's ephemeral filesystem and were destroyed on every recreate —
WhatsApp needed re-pairing after any redeploy or image upgrade. The
`2026.6.11-r3` probe report flagged the state paths as relocation candidates
(Amendment 5 sqlite rule).

- `entrypoint.sh` (root phase): two new relocation symlinks onto the configs
  surface (0700, never synced, never ingested — the same home as
  `exec-approvals.json`): `state → ${AGENT_HOME}/configs/main/state`,
  `credentials → ${AGENT_HOME}/configs/main/credentials`.
- `agent-run.sh` (agent phase): `mkdir -p` both symlink targets before exec —
  must happen as AGENT_UID because squashed root cannot mkdir on the surface.

Exit codes unchanged.

## r3 — 2026-05-22

**Fix: the root phase no longer reads agent-owned files on the NFS surfaces.**

The four surface mounts are bind-mounted host paths that resolve through to
NFS. Under a `root_squash` export the container's root is squashed to
`nobody` and cannot read agent-owned 0600 files — `openclaw.json` and
`secrets.env` are both mode 0600, owned by the agent user. The r2 entrypoint
validated the mounts and `openclaw.json`, and sourced `secrets.env`, all
while still root — so on a root-squashed deploy those steps fail (`die 5`,
`die 7`).

The entrypoint is now split into two phases:

- `entrypoint.sh` (**root phase**): validate environment, provision the agent
  identity, create the relocation symlinks, export `OPENCLAW_STATE_DIR`, then
  `gosu` to the agent user. None of this reads a surface file.
- `agent-run.sh` (**agent phase**, new, runs as `AGENT_UID`): validate the
  surface mounts, validate `openclaw.json`, source `secrets.env`, exec
  openclaw. The agent user owns these files and — unlike squashed-root — can
  read them.

Exit codes are unchanged (3/6 from the root phase, 4/5/7 from the agent
phase, >7 from openclaw). `OPENCLAW_STATE_DIR` (r2) is exported before the
hand-off and survives it.

Companion change in agent-compile: `env_file:` removed from the rendered
`compose.yml` (the Compose CLI cannot read the 0600 NFS `secrets.env`
either) — the entrypoint sources it instead. See
`docs/image-compile-entrypoint-secrets-response-v0_1.md`.

## r2 — 2026-05-21

**Fix: openclaw config discovery is now uid-independent.**

The entrypoint relocates openclaw's state under `/home/agent/.openclaw/` and
drops privileges with `gosu`. `gosu` sets `$HOME` from the target uid's
`/etc/passwd` entry, and openclaw derived its state root from `$HOME`. When
`AGENT_UID` collided with an account already present in the base image
(`node` at 1000, `nobody` at 65534), the entrypoint's `useradd` was skipped,
no `/home/agent` home was registered, and openclaw looked for its config under
the pre-existing account's home — exiting 78 "Missing config".

Changes to `entrypoint.sh`:

- Export `OPENCLAW_STATE_DIR=/home/agent/.openclaw` before the `gosu` exec.
  openclaw now discovers its state directory explicitly, independent of
  `$HOME`, uid, gosu, and the passwd database.
- Warn (non-fatally) when `AGENT_UID` matches a pre-existing account. The
  probe legitimately runs as the operator's own uid, which can collide, so
  this is a diagnostic warning, not a hard failure.

Verified against `node:24-bookworm-slim` + openclaw `2026.5.5`: a container
run with `AGENT_UID=65534` (the colliding `nobody` uid) now boots to
`[gateway] ready` instead of exiting 78.

See `docs/image-compile-uid-collision-response-v0_1.md` in the platform docs
for the full diagnosis.

## r1 — 2026-05-14

Initial wrapper. `node:24-bookworm-slim` + `npm install -g openclaw@<version>`,
tini PID 1, gosu privilege drop, four-surface mount contract, HEALTHCHECK on
HTTP `/healthz`. Built and probe-verified against openclaw `2026.5.5`.
