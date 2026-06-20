# syntax=docker/dockerfile:1.7

# Global ARG: must be declared before the first FROM so it's in scope for the
# stage-2 `FROM ${BASE_IMAGE}`. ARGs declared between FROMs are stage-local
# and cannot be referenced by a subsequent FROM line.
# BASE_IMAGE selects the upstream vLLM runtime to extend:
#   - CUDA: vllm/vllm-openai:vX.Y.Z              (pin to a semver tag)
#   - ROCm: vllm/vllm-openai-rocm:vX.Y.Z         (pin to a semver tag)
ARG BASE_IMAGE=vllm/vllm-openai:v0.23.0

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
# file: FLASHINFER_VERSION (defaults to the v0.23.0 base's pin) and the
# VLLM_WHEEL_URL / VLLM_WHEEL_SHA256 pair, which overlays a pinned per-commit
# wheel from wheels.vllm.ai over the base. See "Building against an unreleased
# vLLM dev commit" in CLAUDE.md.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG ACCEL=cuda
# The flashinfer version for BOTH stable and dev-overlay CUDA builds. Default =
# the v0.23.0 base's pin; it is NOT auto-derived from BASE_IMAGE. When bumping
# the vLLM base for a release, re-check vLLM's flashinfer pin (its
# docker/Dockerfile `ARG FLASHINFER_VERSION` / versions.json) and update this
# default if it moved, or the trio drifts from the base (e.g. 0.22.0 -> 0.23.0
# moved it 0.6.11.post2 -> 0.6.12). When overlaying a dev-commit wheel
# (VLLM_WHEEL_URL below), pass the commit's pin as a build-arg instead. jit-cache
# AOT kernels must match runtime.
ARG FLASHINFER_VERSION=0.6.12

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
# already base deps; jit-cache is the heavy ~1.8GB AOT-kernel add and is NOT a
# default dep. Version is FLASHINFER_VERSION (above) so it can track a dev-commit
# wheel's flashinfer pin; the jit-cache kernels must match the runtime flashinfer
# or they drift. --no-deps is REQUIRED: a flashinfer version bump otherwise
# re-resolves its dependency closure and drags in a conflicting torch (e.g. 0.6.12
# pulls torch 2.9.1 + cuda-toolkit, clobbering the base's 2.11.0+cu130). We keep
# the base's torch and only swap the flashinfer packages. Runs before the vLLM
# overlay so a --no-deps wheel install lands on the intended flashinfer.
RUN if [ "$ACCEL" = "cuda" ]; then \
        pip install --no-cache-dir --no-deps flashinfer-python==${FLASHINFER_VERSION} flashinfer-cubin==${FLASHINFER_VERSION} \
        && pip install --no-cache-dir --no-deps flashinfer-jit-cache==${FLASHINFER_VERSION} --index-url https://flashinfer.ai/whl/cu130; \
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
# The wheel is saved under its REAL filename (decoding %2B -> +): pip derives the
# package/version from the filename, so a generic /tmp/vllm.whl is rejected as a
# malformed wheel name. The post-install gate runs `pip check` but only fails on
# conflicts naming the vLLM stack (torch/vllm/flashinfer/xformers) — the base
# image carries unrelated pre-existing pip-check warts (e.g. pygobject/pycairo)
# we must not trip over.
ARG VLLM_WHEEL_URL=""
ARG VLLM_WHEEL_SHA256=""
RUN if [ -n "${VLLM_WHEEL_URL}${VLLM_WHEEL_SHA256}" ]; then \
        if [ -z "$VLLM_WHEEL_URL" ] || [ -z "$VLLM_WHEEL_SHA256" ]; then \
            echo "ERROR: set BOTH VLLM_WHEEL_URL and VLLM_WHEEL_SHA256, or neither" >&2; exit 1; \
        fi; \
        whl="/tmp/$(basename "$VLLM_WHEEL_URL" | sed 's/%2[bB]/+/g')" \
        && curl -fSL -o "$whl" "$VLLM_WHEEL_URL" \
        && echo "${VLLM_WHEEL_SHA256}  ${whl}" | sha256sum -c - \
        && pip install --no-cache-dir --no-deps "$whl" \
        && rm -f "$whl" \
        && pc="$(pip check 2>&1 || true)" && echo "$pc" \
        && { echo "$pc" | grep -qiE '(torch|vllm|flashinfer|xformers)' \
                && { echo "ERROR: pip check flagged a conflict in the vLLM stack (above)"; exit 1; } \
                || true; } \
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
