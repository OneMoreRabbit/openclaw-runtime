# Changelog — openclaw-runtime wrapper

Wrapper revisions. The `r<rev>` suffix in an image tag (`<upstream>-r<rev>`)
bumps when the wrapper changes without the upstream OpenClaw version moving.
Images built *after* a given entry should use that entry's revision.

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
