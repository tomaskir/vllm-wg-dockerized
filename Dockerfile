# syntax=docker/dockerfile:1.7

# Global ARG: must be declared before the first FROM so it's in scope for the
# stage-2 `FROM ${BASE_IMAGE}`. ARGs declared between FROMs are stage-local
# and cannot be referenced by a subsequent FROM line.
# BASE_IMAGE selects the upstream vLLM runtime to extend:
#   - CUDA: vllm/vllm-openai:vX.Y.Z              (pin to a semver tag)
#   - ROCm: vllm/vllm-openai-rocm:vX.Y.Z         (pin to a semver tag)
ARG BASE_IMAGE=vllm/vllm-openai:v0.22.0

# --------------------------------------------------------------------
# Stage 1: fetch wireproxy (pinned release + sha256 verification)
# --------------------------------------------------------------------
FROM debian:bookworm-slim AS wireproxy-fetch

ARG WIREPROXY_VERSION=v1.1.2
ARG WIREPROXY_SHA256=b7dcff8f6e9d3410364e432aff24154eaa8db8206e0c6faac35d6c6ab06dac51

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN curl -fsSL -o wireproxy.tar.gz \
        "https://github.com/windtf/wireproxy/releases/download/${WIREPROXY_VERSION}/wireproxy_linux_amd64.tar.gz" \
    && echo "${WIREPROXY_SHA256}  wireproxy.tar.gz" | sha256sum -c - \
    && tar -xzf wireproxy.tar.gz \
    && install -m 0755 wireproxy /usr/local/bin/wireproxy

# --------------------------------------------------------------------
# Stage 2: final image extending vLLM.
# ACCEL gates accelerator-specific installs (the CUDA-only flashinfer trio).
# Two knobs make dev/unreleased vLLM builds first-class without editing this
# file: FLASHINFER_VERSION (defaults to the v0.22.0 base's pin) and the
# VLLM_WHEEL_URL / VLLM_WHEEL_SHA256 pair, which overlays a pinned per-commit
# wheel from wheels.vllm.ai over the base. See "Building against an unreleased
# vLLM dev commit" in CLAUDE.md.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG ACCEL=cuda
# Defaults to the v0.22.0 base's flashinfer pin. When overlaying a dev-commit
# wheel (VLLM_WHEEL_URL below), set this to that commit's pin — vLLM's
# docker/Dockerfile `ARG FLASHINFER_VERSION` / versions.json — so the jit-cache
# AOT kernels match the runtime flashinfer the wheel was built against.
ARG FLASHINFER_VERSION=0.6.11.post2

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        wget \
        curl \
        bc \
        jq \
        htop \
        nvtop \
        vim \
        ncdu \
        rsync \
        tcpdump \
        iputils-ping \
        openssl \
        openssh-server \
        ca-certificates \
        python-is-python3 \
        git \
    && rm -rf /var/lib/apt/lists/*

# flashinfer trio (CUDA only), wheel-published for CUDA only. python/cubin are
# already base deps (no-op that documents intent); jit-cache is the heavy ~1.8GB
# add and is NOT a default dep. Version is FLASHINFER_VERSION (above) so it can
# track a dev-commit wheel's flashinfer pin; the jit-cache AOT kernels must
# match the runtime flashinfer or they drift. Installed before the vLLM overlay
# so a --no-deps wheel install lands on the intended flashinfer.
RUN if [ "$ACCEL" = "cuda" ]; then \
        pip install --no-cache-dir flashinfer-python==${FLASHINFER_VERSION} flashinfer-cubin==${FLASHINFER_VERSION} \
        && pip install --no-cache-dir flashinfer-jit-cache==${FLASHINFER_VERSION} --index-url https://flashinfer.ai/whl/cu130; \
    fi

# Optional: pin vLLM to a specific upstream dev commit that has no released
# image yet (e.g. a fix that landed after the last vLLM tag). Point
# VLLM_WHEEL_URL at the immutable per-commit wheel from
# https://wheels.vllm.ai/<full-sha>/... and VLLM_WHEEL_SHA256 at its checksum.
# Both must be set together or the build fails — we never install an unpinned
# wheel (mirrors the wireproxy sha256 gate). Installed --no-deps so the base's
# torch/xformers stack and the flashinfer pinned above are preserved: only
# coherent when the target commit shares the base's torch pin (verify) and
# FLASHINFER_VERSION matches the commit's pin. Unset for release builds — no-op.
ARG VLLM_WHEEL_URL=""
ARG VLLM_WHEEL_SHA256=""
RUN if [ -n "${VLLM_WHEEL_URL}${VLLM_WHEEL_SHA256}" ]; then \
        if [ -z "$VLLM_WHEEL_URL" ] || [ -z "$VLLM_WHEEL_SHA256" ]; then \
            echo "ERROR: set BOTH VLLM_WHEEL_URL and VLLM_WHEEL_SHA256, or neither" >&2; exit 1; \
        fi; \
        curl -fSL -o /tmp/vllm.whl "$VLLM_WHEEL_URL" \
        && echo "${VLLM_WHEEL_SHA256}  /tmp/vllm.whl" | sha256sum -c - \
        && pip install --no-cache-dir --no-deps /tmp/vllm.whl \
        && rm -f /tmp/vllm.whl \
        && pip check \
        && python -c "import importlib.metadata as m; print('vLLM pinned to', m.version('vllm'))"; \
    fi
RUN pip install --no-cache-dir lm_eval 'lm_eval[api]' inspect_ai inspect_evals instanttensor
# HF Hub is fully Xet-backed now: hf_transfer is deprecated and unused, and
# huggingface_hub auto-installs the hf-xet backend. HF_XET_HIGH_PERFORMANCE is
# the Xet equivalent of the old HF_HUB_ENABLE_HF_TRANSFER=1 fast-transfer flag.
ENV HF_XET_HIGH_PERFORMANCE=1

COPY --from=wireproxy-fetch /usr/local/bin/wireproxy /usr/local/bin/wireproxy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
