# openclaw-runtime

ARC Power wrapper image for upstream [OpenClaw](https://github.com/openclaw/openclaw). One thin
Dockerfile plus an entrypoint that wires the upstream binary into the platform's four-surface mount
contract. No fork; no patched upstream code.

This repository is the **openclaw** flavour's wrapper. Other flavours (nanoclaw, ...) live in
sibling repos with the same shape.

## Design

The wrapper image is fully described in:

- [openclaw-image-architecture-v0_2.md](../integrations/openclaw-image-architecture-v0_2.md) — design contract: mounts, identity, symlink relocation, exit codes.
- [openclaw-image-build-process-v0_2.md](../integrations/openclaw-image-build-process-v0_2.md) — how versions are pinned, tagged, smoke-tested, published.

The build, probe, and registry pairing is owned by `image-compile` ([brief](../integrations/image-compile-build-brief-v0_1.md), [amendments](../docs/image-compile-brief-amendments-v0_1.md)).

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
[architecture doc §Entrypoint behaviour](../integrations/openclaw-image-architecture-v0_2.md) for
the full table.

## Status

Phase 0 scaffold. Buildable, but the entrypoint has not yet been verified against a real upstream
boot — that's Phase 1 of `image-compile`.
