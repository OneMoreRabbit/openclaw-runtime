# openclaw-runtime examples

Minimal smoke-test compose stack.

## Setup (one-off)

The wrapper's entrypoint validates that the four surface mounts exist as non-empty directories
before openclaw is execed. The example expects host-side directories at `./surfaces/<surface>/main/`
with the smoke config + secrets pre-placed.

```bash
mkdir -p surfaces/configs/main surfaces/memory/main surfaces/sessions/main surfaces/scratch/main
cp openclaw.json surfaces/configs/main/openclaw.json
cp secrets.env   surfaces/configs/main/secrets.env
chmod 0600 surfaces/configs/main/secrets.env
```

The compose stack runs the container as uid 65534 (nobody) — make sure the surface directories are
writable by that uid, or `chown -R 65534:65534 surfaces/`.

## Run

```bash
docker compose up -d
sleep 15
curl -fsS http://127.0.0.1:18789/healthz && echo OK
docker compose logs openclaw
docker compose down -v
```

## Teardown

```bash
docker compose down -v
rm -rf surfaces/
```

## Notes

This compose stack is for human-driven smoke verification of the wrapper image. `image-compile` does
its own probe with a richer stub config; do not use this stack as a substitute for the probe.
