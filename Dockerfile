# syntax=docker/dockerfile:1.7

# openclaw-runtime — ARC Power wrapper image for upstream OpenClaw.
#
# r10 (ADR-0013): the container is a small Ubuntu machine, not an app wrapper.
# One image line, no variants. Contents are fixed by D3 of that ADR — a tool
# not in its table is added by amending the ADR, never by a build arg.
#
# Pinned upstream version is passed at build time via OPENCLAW_VERSION (no v prefix).
# Design contract: components/agent-image/docs/openclaw-image-architecture-v0_3.md

# D2 — the constitution's platform (principle 6), inside the container as well
# as outside. Replaces node:24-bookworm-slim.
ARG UBUNTU_BASE=ubuntu:24.04
FROM ${UBUNTU_BASE}

ARG OPENCLAW_VERSION
ARG NODE_MAJOR=24

# D1 — OPENCLAW_VARIANT and OPENCLAW_EXTRA_APT are RETIRED. They were the escape
# hatch that reintroduced per-agent image drift, which the architecture exists to
# prevent. A build that passes them should fail loudly rather than ignore them.
ARG OPENCLAW_VARIANT=""
ARG OPENCLAW_EXTRA_APT=""
RUN if [ -n "${OPENCLAW_VARIANT}" ] || [ -n "${OPENCLAW_EXTRA_APT}" ]; then \
      echo "OPENCLAW_VARIANT and OPENCLAW_EXTRA_APT are retired (ADR-0013 D1)." >&2; \
      echo "One image line, no variants. Add tools by amending D3, not per build." >&2; \
      exit 1; \
    fi

RUN if [ -z "${OPENCLAW_VERSION}" ]; then \
      echo "OPENCLAW_VERSION build arg is required" >&2; exit 1; \
    fi

ENV DEBIAN_FRONTEND=noninteractive

# D3 — the contents table, exactly. Nothing else.
#   python3 / git / curl  the agent's working tools
#   openssh-server        D6; presence, not access
#   gosu / tini           identity drop and PID 1, as r9
#   ca-certificates       TLS for npm and curl
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 openssh-server gosu tini; \
    rm -rf /var/lib/apt/lists/*

# node 24.x. Ubuntu 24.04 ships an older node, so the pinned major comes from
# NodeSource. openclaw does not start without it.
RUN set -eux; \
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh; \
    bash /tmp/nodesource_setup.sh; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/* /tmp/nodesource_setup.sh; \
    node --version; npm --version

# D4 — the agent is an ordinary user with no route to root. `sudo` is not in the
# contents table; assert its absence rather than assume the base omits it, so
# "no runtime installs" is enforced by privilege and not by a rule.
RUN set -eux; \
    apt-get purge -y sudo 2>/dev/null || true; \
    rm -rf /var/lib/apt/lists/*; \
    if command -v sudo >/dev/null 2>&1; then \
      echo "sudo is present in the image; ADR-0013 D4 forbids it" >&2; exit 1; \
    fi

RUN npm install -g openclaw@${OPENCLAW_VERSION}

# r8 (supersedes r7's /opt/openclaw-plugins bake): plugins bake as BUNDLED
# extensions in the runtime's stock root, because 2026.6.x gates
# security-sensitive plugin APIs on provenance — `openKeyedStore is only
# available for trusted plugins` unless origin === "bundled".
#
# Each spec MUST be pinned. Baked ≠ enabled: inert until per-agent config
# enables them. Collision guard: if upstream ever ships a stock plugin with the
# same id, the build FAILS rather than clobbering.
#
# r8.1: after extraction the plugin's `openclaw` manifest block is normalised —
# npm-published plugins declare SOURCE-form specifiers that only the runtime
# installer's alias table can bridge; a bundled record has none, so channel
# submodule loads fail. The normaliser rewrites each specifier to the built file
# and FAILS the build if no built equivalent exists.
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

# D6 — sshd is present, key-gated, and presence is not access.
#   * password auth off, root login off, keys only;
#   * NO authorized_keys is shipped — the file's ABSENCE is the closed door, and
#     an empty file is a different fact. The deployer places it per agent at
#     /home/agent/.ssh/authorized_keys (mode 0600, owned by the agent uid).
#   * NO host keys are baked. Baking them would give every agent container in
#     the estate the same host identity, so the entrypoint generates them on
#     first start into the container's own filesystem.
RUN set -eux; \
    mkdir -p /etc/ssh/sshd_config.d /run/sshd; \
    printf '%s\n' \
      '# ADR-0013 D6 — keys only; presence is not access.' \
      'PasswordAuthentication no' \
      'PermitEmptyPasswords no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'PubkeyAuthentication yes' \
      'AuthorizedKeysFile .ssh/authorized_keys' \
      > /etc/ssh/sshd_config.d/10-arcpower.conf; \
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub; \
    rm -f /home/agent/.ssh/authorized_keys

RUN mkdir -p /opt/wrapper /home/agent /agent/configs /agent/memory /agent/sessions /agent/scratch \
 && chmod 0755 /home/agent

COPY entrypoint.sh agent-run.sh /opt/wrapper/
RUN chmod 0755 /opt/wrapper/entrypoint.sh /opt/wrapper/agent-run.sh

ENV OPENCLAW_BIND=lan \
    OPENCLAW_PORT=18789 \
    OPENCLAW_EXTRA_ARGS="" \
    AGENT_HOME=/agent \
    SSHD_PORT=22

LABEL org.opencontainers.image.title="openclaw-runtime" \
      org.opencontainers.image.description="ARC Power wrapper for pinned upstream OpenClaw"

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.OPENCLAW_PORT||18789)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/wrapper/entrypoint.sh"]
