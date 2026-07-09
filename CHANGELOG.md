# Changelog — openclaw-runtime wrapper

Wrapper revisions. The `r<rev>` suffix in an image tag (`<upstream>-r<rev>`)
bumps when the wrapper changes without the upstream OpenClaw version moving.
Images built *after* a given entry should use that entry's revision.

## r8.1 — 2026-07-09

**Fix: bundled plugins' manifest specifiers normalise to built files at
bake time.**

`2026.6.11-r8` probed green but failed at template test, in channel start —
a path the probe didn't exercise: `[channels] failed to load
persistedAuthState checker for whatsapp: plugin module path escapes plugin
root or fails alias checks`. Root cause (full evidence chain in the r8
brief's r8.1 addendum): npm-published plugins declare SOURCE-form
specifiers in their `openclaw` block (`extensions: ["./index.ts"]`,
`channel.persistedAuthState.specifier: "./auth-presence"`) that only the
runtime installer's alias table bridges to the built files; a
directory-scanned bundled record has no alias table. The npm form assumes
the installer; the in-tree stock form assumes prebuilt flatness; r8
shipped a third shape satisfying neither.

- New `normalize-plugin-manifest.js`, run per plugin at bake time after
  extraction: rewrites every relative specifier in the `openclaw` block to
  its built equivalent (`./index.ts → ./dist/index.js`,
  `./auth-presence → ./dist/auth-presence.js`; already-built specifiers
  like `./dist/setup-entry.js` are left alone), so every specifier
  resolves as a plain in-root path — no alias layer needed.
- **Guard: unresolved specifiers fail the build.** An upstream renaming
  its built files breaks the bake, never a channel start.
- Companion (image-compile): the probe now boots the stub with one channel
  ENABLED (`channel_start_check`, dummy policy) so channel start is
  exercised, and fails the build on any plugin LOAD error in the logs
  (`pushPluginLoadError` / "escapes plugin root" / "alias checks").
  Load success only — stub creds can never connect. The injected channel
  block is scrubbed from the captured bundle config.

r8 was pushed to GHCR, so this mints **r8.1** rather than rebuilding the
r8 tag in place (same-tag-different-content is the r3 incident class).
No live agent ever ran r8; zaph stays on r7 until r8.1.

Exit codes unchanged; entrypoint/agent-run untouched.

## r8 — 2026-07-09

**Fix: baked plugins land as BUNDLED stock extensions, not out-of-tree.**

r7's `/opt/openclaw-plugins` + `plugins.load.paths` bake loaded plugins,
but 2026.6.x gates security-sensitive plugin APIs on provenance. Live on
`agent_top_zaph`: WhatsApp paired (`linked`) but the provider died with
`openKeyedStore is only available for trusted plugins in this release` —
the shipped runtime's gate reads
`if (record?.origin !== "bundled" && record?.trustedOfficialInstall !== true) throw`.
`trustedOfficialInstall` is only written by the runtime's own installer
(impractical on an NFS state dir; hand-setting an undocumented flag is
fragile across upstreams). `origin === "bundled"` is the durable route.
Two more r7 symptoms shared the out-of-tree root and dissolve with it: the
CLI lane not recognising baked plugins (`Install WhatsApp plugin?` prompt)
and the `duplicate plugin id` warning from double discovery.

- `BAKED_PLUGINS` packages now extract (`npm pack`) into the runtime's
  stock extensions root
  `/usr/local/lib/node_modules/openclaw/dist/extensions/<id>/`, each with
  its own production `node_modules` (`require('openclaw')` resolves by
  walking up to `/usr/local/lib/node_modules`).
- **No path config at all**: image-compile stops emitting
  `plugins.load.paths` (the r7 mechanism). Enablement is unchanged —
  per-agent config, same knobs as stock plugins.
- **Collision guard**: the build FAILS if `dist/extensions/<id>` already
  exists — an upstream shipping a same-named stock plugin is a conscious
  reconciliation, never a clobber.
- **Layout assertion** (image-compile probe): `dist/extensions/` is
  upstream-internal, not a published interface. The probe asserts every
  baked id appears under the stock source root in `plugins list` and that
  no duplicate-id warning is logged — an upstream layout change fails the
  build, not a deployed agent.

**Upstream-upgrade caveat:** `dist/` is replaced whenever the upstream
version bumps. That is by design — the bake re-runs on every image build —
but do not expect plugins to survive an in-container `npm upgrade`
(unsupported on this platform anyway; images are immutable, rebuilds are
the upgrade path).

Exit codes unchanged; entrypoint/agent-run untouched.

## r7 — 2026-07-08

**Feature: channel/provider plugins bake into the image at build time.**

r6 made surface-installed plugins persistent, and it holds for small
packages (brave). But npm-scale many-small-file work against the NFS
configs surface is pathological: `@openclaw/whatsapp` and
`@openclaw/discord` installs failed — first via the /tmp→NFS staging move
(EXDEV-class, no copy fallback), then, with `TMPDIR` on the surface, via
the fixed 120s extract timeout. Decision: the standard plugin set ships in
the image.

- New `BAKED_PLUGINS` build ARG: space-separated **pinned** npm specs
  (`@openclaw/whatsapp@2026.6.11 …`), supplied by image-compile from the
  flavour config, versions locked to the upstream (lockstep releases).
  Unpinned specs fail the build.
- Each spec installs at build time into `/opt/openclaw-plugins/<id>/`
  (`<id>` = package basename minus any `-plugin` suffix: `brave`,
  `whatsapp`, `discord`, `perplexity`) in the same npm-project shape
  `openclaw plugins install` produces: `package.json`, `node_modules/`,
  and a peer link `node_modules/openclaw →
  /usr/local/lib/node_modules/openclaw`.
- **Baked ≠ enabled.** Plugin code is inert until per-agent config enables
  it (like the disabled stock plugins). Discovery is plain config —
  `plugins.load.paths: ["/opt/openclaw-plugins/<id>", …]` — emitted by
  image-compile's probe stub so the captured defaults bundle carries it;
  enablement stays per-agent (`plugins.entries.<id>.enabled`, channel
  config). No install verb at runtime; recreate-stable by construction.
- The r6 `npm/` surface relocation stays — still correct for small ad-hoc
  plugins. Boundary evidence for the size caveat: staging-move failure,
  then `extract tar timed out after 120000ms` with
  `TMPDIR=/agent/configs/main/tmp` honoured.

Exit codes unchanged; entrypoint/agent-run untouched.

## r6 — 2026-07-08 (amended same day; no r6 image was built from the earlier entry)

**Restructure: `OPENCLAW_STATE_DIR` now points directly at the configs
surface. State-dir entries are real files — no relocation symlinks.**

Three failures in one week, all casualties of the r1–r5 per-path symlink
model:

1. r5: the 2026.6.x legacy session migration `rename()`d across a symlink
   boundary (`EXDEV`).
2. r6 as filed: plugin code (`openclaw plugins install`, 2026.6.x
   pluginised providers/channels) landed under `$OPENCLAW_STATE_DIR/npm` —
   the one state-dir writable left unrelocated. Ephemeral code + persistent
   config registration = gateway crash-loop on recreate
   (`web_search provider is not available: brave`).
3. r6 addendum, live on `agent_top_zaph`: the runtime **refuses to write
   `exec-approvals.json` through a symlink** (`[tools] exec failed:
   Refusing to write exec approvals via symlink`). A per-file symlink can
   never satisfy that check, and the wrapper cannot add bind mounts — the
   only wrapper-side fix is for the state dir itself to resolve to the
   surface.

So r6 inverts the model instead of adding a ninth symlink:

- `entrypoint.sh` (root phase): `export
  OPENCLAW_STATE_DIR=${AGENT_HOME}/configs/main`. Every state-dir entry —
  `openclaw.json`, `exec-approvals.json`, `state/`, `credentials/`,
  `agents/`, `npm/`, and whatever future runtimes add — is a **real
  file/dir** on the configs surface (0700, never synced, never ingested).
  Secrets-safe and persistent **by default**. `~/.openclaw` is kept as an
  empty dir (residual hardcoded paths fail soft; the probe's
  relocation-candidate summary would surface any write landing there).
- **The on-surface layout is byte-identical to r4/r5's** —
  `configs/main/{openclaw.json,state,credentials,agents,npm}` — so
  existing deployments (zaph) carry over with **zero data migration**.
- `agent-run.sh` (agent phase, as `AGENT_UID` — root_squash: root cannot
  write to the export): entries belonging on *other* surfaces stay
  symlinks, now living on the surface (persistent, idempotently re-placed):
  `workspace → memory/main/workspace`, `memory → memory/main/openclaw_memory`,
  `scratch → scratch/main`, and the r5 per-id session leaves
  `agents/<id>/sessions → sessions/<id>/sessions` (unchanged semantics). A
  real dir found at any of these paths has its contents moved across before
  the symlink is placed.
- `logs → /tmp/openclaw-logs` (container-local): preserves the
  logs-stay-ephemeral decision — `docker logs` is the diagnostic surface;
  gateway log chatter doesn't belong on NFS, nor secrets-in-logs on a share
  that outlives the container.
- `exec-approvals.json` is deliberately **not seeded**: with no symlink in
  its path the runtime creates and maintains its own file (the refusal was
  symlink-specific); seeding a guessed schema risks breaking approvals a
  second way.

The `openclaw` peerDependency symlink inside each plugin project targets
`/usr/local/lib/node_modules/openclaw` — present in every wrapper image, so
installed plugins survive image upgrades (re-install only on
upstream-compat breaks).

**Migration notes:** plugins installed on r5 or earlier are gone (they were
ephemeral); if their registration lingers in `openclaw.json` the gateway
will not start until the plugin is reinstalled once (now persistent) or
deregistered. Approvals recorded before r6 lived behind the refused symlink
(i.e. nowhere) — expect a clean approvals file.

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
