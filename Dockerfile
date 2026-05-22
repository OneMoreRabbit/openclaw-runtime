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
