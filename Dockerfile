# syntax=docker/dockerfile:1.7

# openclaw-runtime — ARC Power wrapper image for upstream OpenClaw.
# Pinned upstream version is passed at build time via OPENCLAW_VERSION (no v prefix).
# See integrations/openclaw-image-architecture-v0_2.md for the design contract.

ARG NODE_BASE=node:24-bookworm-slim
FROM ${NODE_BASE}

ARG OPENCLAW_VERSION
ARG OPENCLAW_EXTRA_APT=""

RUN if [ -z "${OPENCLAW_VERSION}" ]; then \
      echo "OPENCLAW_VERSION build arg is required" >&2; exit 1; \
    fi

# gosu is used by the entrypoint to drop privileges to the runtime agent user.
# tini provides a sane PID 1 inside the container.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gosu tini ca-certificates ${OPENCLAW_EXTRA_APT}; \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g openclaw@${OPENCLAW_VERSION}

# r8 (supersedes r7's /opt/openclaw-plugins bake): plugins bake as BUNDLED
# extensions in the runtime's stock root, because 2026.6.x gates
# security-sensitive plugin APIs on provenance — `openKeyedStore is only
# available for trusted plugins` unless origin === "bundled" (or the
# runtime's own installer wrote trustedOfficialInstall, impractical on an
# NFS state dir). Bundled also fixes CLI recognition and kills the r7
# duplicate-discovery warning; no path config is needed at all.
#
# Each spec MUST be pinned (`@openclaw/whatsapp@2026.6.11`). The package is
# extracted (npm pack) into dist/extensions/<id>/ with its own production
# node_modules; `require('openclaw')` resolves by walking up to
# /usr/local/lib/node_modules. Baked ≠ enabled: inert until per-agent
# config enables them, exactly like the disabled stock plugins.
#
# Collision guard: if an upstream ever ships a stock plugin with the same
# id, the build FAILS — reconciling that is a conscious decision, never a
# clobber. NOTE: dist/extensions is upstream-internal, not a published
# interface; image-compile's probe asserts each baked id appears under the
# stock source root in `plugins list`, so an upstream layout change fails
# the build, not a deployed agent.
#
# r8.1: after extraction, the plugin's `openclaw` manifest block is
# normalised — npm-published plugins declare SOURCE-form specifiers
# ("./index.ts", "./auth-presence") that only the runtime installer's alias
# table can bridge; a bundled record has none, so channel submodule loads
# fail ("escapes plugin root or fails alias checks"). The normaliser
# rewrites each specifier to the actual built file and FAILS the build if
# no built equivalent exists.
COPY normalize-plugin-manifest.js /opt/wrapper/
ARG BAKED_PLUGINS=""
RUN set -eux; \
    if [ -n "${BAKED_PLUGINS}" ]; then \
      EXT_ROOT="/usr/local/lib/node_modules/openclaw/dist/extensions"; \
      mkdir -p "${EXT_ROOT}"; \
      for spec in ${BAKED_PLUGINS}; do \
        name="${spec%@*}"; \
        if [ -z "${name}" ] || [ "${name}" = "${spec}" ]; then \
          echo "BAKED_PLUGINS entries must be pinned name@version specs (got: ${spec})" >&2; \
          exit 1; \
        fi; \
        base="${name##*/}"; \
        id="${base%-plugin}"; \
        dest="${EXT_ROOT}/${id}"; \
        if [ -e "${dest}" ]; then \
          echo "collision: ${dest} already exists — upstream now ships a stock '${id}'?" >&2; \
          echo "Reconcile deliberately (drop it from baked_plugins or rename); refusing to clobber." >&2; \
          exit 1; \
        fi; \
        staging="$(mktemp -d)"; \
        cd "${staging}"; \
        npm pack "${spec}" >/dev/null; \
        tar -xzf ./*.tgz; \
        mkdir -p "${dest}"; \
        cp -a package/. "${dest}/"; \
        cd "${dest}"; \
        npm install --omit=dev --no-audit --no-fund; \
        node /opt/wrapper/normalize-plugin-manifest.js "${dest}"; \
        rm -rf "${staging}"; \
      done; \
    fi

RUN mkdir -p /opt/wrapper /home/agent /agent/configs /agent/memory /agent/sessions /agent/scratch \
 && chmod 0755 /home/agent

COPY entrypoint.sh agent-run.sh /opt/wrapper/
RUN chmod 0755 /opt/wrapper/entrypoint.sh /opt/wrapper/agent-run.sh

ENV OPENCLAW_BIND=lan \
    OPENCLAW_PORT=18789 \
    OPENCLAW_EXTRA_ARGS="" \
    AGENT_HOME=/agent

LABEL org.opencontainers.image.title="openclaw-runtime" \
      org.opencontainers.image.description="ARC Power wrapper for pinned upstream OpenClaw"

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.OPENCLAW_PORT||18789)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/wrapper/entrypoint.sh"]
