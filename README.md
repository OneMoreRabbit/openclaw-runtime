# openclaw-runtime

ARC Power wrapper image for upstream [OpenClaw](https://github.com/openclaw/openclaw). One thin
Dockerfile plus an entrypoint that wires the upstream binary into the platform's four-surface mount
contract. No fork; no patched upstream code.

This repository is the **openclaw** flavour's wrapper. Other flavours (nanoclaw, ...) live in
sibling repos with the same shape.

## Design

The wrapper image is fully described in:

Design docs live in the **Atlas-AgentEco** vault, not in this repo (constitution principle 3:
one home each). Paths are relative to the vault root; this seat syncs it to `.atlas/`.

- `components/agent-image/docs/openclaw-image-architecture-v0_2.md` — design contract: mounts, identity, symlink relocation, exit codes.
- `components/agent-image/docs/manual/openclaw-image-build-process-v0_2.md` — how versions are pinned, tagged, smoke-tested, published.
- `components/agent-image/docs/provides/openclaw-image-platform-handover-v0_3.md` — the deployment contract, current as of ADR-0010.

The previous links pointed at `../integrations/`, a sibling directory that has not existed
since the pre-vault migration.

The build, probe, and registry pairing is owned by `image-compile` — the other repo of this
component.

## Build (manual, for development)

```bash
docker buildx build \
  --build-arg OPENCLAW_VERSION=2026.5.5 \
  --tag openclaw-runtime:2026.5.5-r1 \
  --load .
```

For production builds, use `image-compile build openclaw v2026.5.5` — it handles tagging, smoke,
probe, bundle, and push atomically.

## Local smoke test

```bash
cd examples/
docker compose up -d
sleep 15
curl -fsS http://127.0.0.1:18789/healthz && echo OK
docker compose down -v
```

The example compose stack creates the four surface directories under `./surfaces/`, populates a
minimal openclaw.json, and runs the wrapper at a non-privileged UID/GID. Expected outcome:
`/healthz` returns 200 within 15s.

## Exit codes

The entrypoint uses exit codes 3–7; the upstream openclaw binary uses anything above. See
the architecture doc §Entrypoint behaviour (vault, path above) for
the full table.

## Status

Current wrapper revision: **r3** (see [CHANGELOG.md](CHANGELOG.md)). Built and probe-verified
against openclaw `2026.5.5`. r2 pinned `OPENCLAW_STATE_DIR` so config discovery is uid-independent;
r3 splits the entrypoint into a root phase (`entrypoint.sh`) and an agent phase (`agent-run.sh`) so
the agent-owned surface files are read by the agent user, not by root — required for `root_squash`
NFS exports.
