# syntax=docker/dockerfile:1.7

# Global ARG: must be declared before the first FROM so it's in scope for the
# stage-2 `FROM ${BASE_IMAGE}`. ARGs declared between FROMs are stage-local
# and cannot be referenced by a subsequent FROM line.
# BASE_IMAGE selects the upstream vLLM runtime to extend:
#   - CUDA: vllm/vllm-openai:vX.Y.Z              (pin to a semver tag)
#   - ROCm: vllm/vllm-openai-rocm:vX.Y.Z         (pin to a semver tag)
ARG BASE_IMAGE=vllm/vllm-openai:v0.34.0

# --------------------------------------------------------------------
# Stage 1: build wireproxy from a pinned upstream commit
# --------------------------------------------------------------------
# Built from source rather than fetched as a release tarball: the newest release
# (v1.1.3) predates two TCPServerTunnel fixes that only exist on master —
# windtf/wireproxy#222 (every closed tunnel connection logged
# "ERROR: Cannot forward traffic: ... use of closed network connection" through
# wireproxy's own logger, which -s does not silence) and #223 (a refused
# loopback target, e.g. vLLM still loading, left the WG-side connection open
# until the peer timed out). Integrity is pinned end to end: the golang image by
# digest, the source by full commit SHA (content-addressed — the checkout is
# verified against it), and every Go module by the repo's go.sum. Go back to
# the release-tarball + sha256 fetch once a release containing both fixes ships.
FROM golang:1.26.11-bookworm@sha256:dc40a13b61304647ed7e5d581d246b86413dfc29d63c6d018310feb93cd98fc0 AS wireproxy-build

ARG WIREPROXY_COMMIT=a4c5269015608fd202b61c746429ce9c278ae69e
# Reported by `wireproxy -v`; git-describe form of WIREPROXY_COMMIT.
ARG WIREPROXY_VERSION=v1.1.3-7-ga4c5269

WORKDIR /src
RUN git init -q . \
    && git fetch -q --depth 1 https://github.com/windtf/wireproxy.git "${WIREPROXY_COMMIT}" \
    && git checkout -q FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${WIREPROXY_COMMIT}" \
    && go mod verify \
    && CGO_ENABLED=0 GOTOOLCHAIN=local go build -trimpath \
        -ldflags "-s -w -X 'main.version=${WIREPROXY_VERSION}'" \
        -o /usr/local/bin/wireproxy ./cmd/wireproxy \
    && /usr/local/bin/wireproxy -v

# --------------------------------------------------------------------
# Stage 2: final image extending vLLM.
# ACCEL gates accelerator-specific installs (the CUDA-only flashinfer trio).
# Two knobs make dev/unreleased vLLM builds first-class without editing this
# file: FLASHINFER_VERSION (defaults to the v0.34.0 base's pin) and the
# VLLM_WHEEL_URL / VLLM_WHEEL_SHA256 pair, which overlays a pinned per-commit
# wheel from wheels.vllm.ai over the base. See "Building against an unreleased
# vLLM dev commit" in CLAUDE.md.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG ACCEL=cuda
# The flashinfer version for BOTH stable and dev-overlay CUDA builds. Default =
# the v0.34.0 base's pin; it is NOT auto-derived from BASE_IMAGE. When bumping
# the vLLM base for a release, re-check vLLM's flashinfer pin (the release tag's
# requirements/cuda.txt `flashinfer-python==`; v0.32.0 dropped the old
# docker/Dockerfile `ARG FLASHINFER_VERSION` and its versions.json entry) and
# update this default if it moved, or the trio drifts from the base (e.g. 0.22.0 -> 0.23.0
# moved it 0.6.11.post2 -> 0.6.12; 0.23.0 -> 0.24.0 left it at 0.6.12;
# 0.24.0 -> 0.25.1 moved it 0.6.12 -> 0.6.13; 0.25.1 -> 0.27.1 moved it
# 0.6.13 -> 0.6.16.post3; 0.27.1 -> 0.28.0 left it at 0.6.16.post3;
# 0.28.0 -> 0.29.0 moved it 0.6.16.post3 -> 0.6.18; 0.29.0 -> 0.30.0 moved it
# 0.6.18 -> 0.6.18.post1; 0.30.0 -> 0.31.0 moved it 0.6.18.post1 ->
# 0.7.0.post1; 0.31.0 -> 0.32.0 left it at 0.7.0.post1; 0.32.0 -> 0.33.0 moved it
# 0.7.0.post1 -> 0.7.2.post1; 0.33.0 -> 0.34.0 moved it 0.7.2.post1 -> 0.7.3).
# When overlaying a dev-commit wheel (VLLM_WHEEL_URL below), pass the commit's
# pin as a build-arg instead. jit-cache AOT kernels must match runtime.
ARG FLASHINFER_VERSION=0.7.3
# Wheel index for flashinfer-jit-cache. The cuXXX suffix must match the base
# torch's CUDA build (the +cuXXX in torch.__version__), which moves
# independently of FLASHINFER_VERSION when the base bumps its CUDA toolchain —
# re-check it on every vLLM base bump. Still cu130 at v0.34.0 (image config
# CUDA_VERSION=13.0.2). v0.33.0 stopped publishing the -cu129 image variants
# (upstream PR #62575), so CUDA 13.0 is the only CUDA build.
ARG FLASHINFER_CUDA_INDEX=cu130

# Both streams carry every package below, but they no longer share a distro:
# the CUDA runtime base moved to Ubuntu 24.04 (noble) at vLLM v0.28.0 (upstream
# PR #51058) while the ROCm base is still on 22.04 (jammy) — including the
# ROCm 10.0 image that became the default at v0.33.0 (and the only ROCm image
# since v0.34.0). Keep additions to
# packages that exist in both.
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
    && rm -rf /var/lib/apt/lists/* \
    # openssh-server's postinst generates host keys at install time, which would
    # bake identical (and publicly-pullable) host keys into every container from
    # this image. Delete them; the entrypoint's `ssh-keygen -A` then generates
    # fresh per-container keys at startup.
    && rm -f /etc/ssh/ssh_host_*

# flashinfer trio (CUDA only), wheel-published for CUDA only. The upstream CUDA
# image already ships all three at the base's pin (since v0.32.0 via
# `flashinfer download-kernels`, upstream PR #58765), so on release builds this
# layer is a no-op that fails loudly if our pin ever drifts from the base. It
# matters for dev-commit overlays, where FLASHINFER_VERSION tracks the commit's
# pin; the jit-cache kernels must match the runtime flashinfer or they drift.
# python/cubin: --no-deps is REQUIRED — a flashinfer version bump otherwise
# re-resolves its dependency closure and drags in a conflicting torch (e.g. 0.6.12
# pulls torch 2.9.1 + cuda-toolkit, clobbering the base's torch — 2.14.0+cu130 as
# of the v0.34.0 base). The root flashinfer.ai index is an EXTRA index because
# flashinfer-cubin left PyPI after 0.6.13.
# jit-cache: since 0.7.0, flashinfer-jit-cache is a ~5KB shim whose only
# dependencies are the per-arch provider wheels (flashinfer-jit-cache-sm80,
# -sm90a, -sm100a, ...) that hold the AOT kernels, each pinned to the shim's
# exact version and dependency-free. It must therefore install WITH deps —
# --no-deps would swap only the shim and leave mismatched providers that the
# runtime rejects, silently falling back to JIT. This is safe without --no-deps
# because --index-url confines resolution to the flashinfer cuXXX index, which
# carries no torch. Runs before the vLLM overlay so a --no-deps wheel install
# lands on the intended flashinfer.
RUN if [ "$ACCEL" = "cuda" ]; then \
        pip install --no-cache-dir --no-deps flashinfer-python==${FLASHINFER_VERSION} flashinfer-cubin==${FLASHINFER_VERSION} \
            --extra-index-url https://flashinfer.ai/whl/ \
        && pip install --no-cache-dir flashinfer-jit-cache==${FLASHINFER_VERSION} --index-url https://flashinfer.ai/whl/${FLASHINFER_CUDA_INDEX}; \
    fi

# amd-quark (ROCm only): AMD's Quark quantization runtime. vLLM refuses to load
# MX-FP4 / Quark-quantized models without it ("The package `amd-quark` is required
# to use MX-FP4 models."). Through v0.25.1 this repo installed it because the
# published vllm-openai-rocm image did not bake it in — but as of the v0.27.x
# base (still true at v0.34.0, whose only image is ROCm 10) upstream hard-pins
# `amd-quark==0.12.post1` in requirements/rocm.txt, bakes it into the image (verified in the published
# layers back to v0.25.1), and the ROCm-built vLLM wheel declares
# `Requires-Dist: amd-quark==0.12.post1`. An install pin here would therefore
# either be a no-op or, worse, DOWNGRADE a future base whose pin moved and break
# its vllm dependency. So this is now an ASSERT, not an install: fail the build
# loudly if a future ROCm base ever ships without amd-quark again — then decide
# the right version from that base's requirements/rocm.txt rather than
# auto-installing a stale pin.
RUN if [ "$ACCEL" = "rocm" ]; then \
        python -c "import importlib.metadata as m; print('amd-quark baked into base:', m.version('amd-quark'))" \
        || { echo "ERROR: ROCm base no longer ships amd-quark; re-add an explicit install matched to this base's requirements/rocm.txt" >&2; exit 1; }; \
    fi

# Eval tooling (both streams): benchmark the served model from inside the
# rental. Unlike flashinfer these install WITH deps so their trees resolve.
# The upstream base itself is not pip-check clean: CUDA deliberately overrides
# torch's NCCL pin via UV_OVERRIDE (torch 2.14.0 pins nvidia-nccl-cu13 2.30.7,
# the image ships 2.31.2), and v0.34.0's LMCache install leaves OpenTelemetry
# below vLLM's own floor (vllm-project/vllm#67259, fix PR #67274). So the gate
# is baseline-relative: every installed vLLM-stack dist becomes a pip
# constraint (pip has no uv-style override, so this is what keeps pip from
# "repairing" NCCL back to torch's pin), and only stack conflicts the install
# ADDS fail the build, plus a diff of the stack itself. instanttensor is a
# vLLM load-format plugin the CUDA base already ships (requirements/cuda.txt);
# naming it again drags torch into the resolve, so it is installed only where
# missing (ROCm). vLLM requirements the base leaves unmet are re-resolved here
# (a no-op once upstream ships #67274); LMCache's OTel caps then remain as
# accepted unmet lines, as in upstream CI. set -f: the unmet specifiers are
# expanded unquoted and may contain globs (e.g. protobuf's !=6.30.*). Sits
# BEFORE the overlay — the most frequently changing step — so changing that
# doesn't invalidate this heavy download layer.
RUN set -ef; \
    stack='(torch|pytorch[-_]triton|triton|vllm|flashinfer|xformers|nvidia[-_]|cuda[-_]|aiter|amd[-_]quark|rocm)'; \
    norm() { sed -E 's/^([^ ]+) [^ ]+ has requirement/\1 has requirement/' | sort; }; \
    pip list --format=freeze | grep -iE "^$stack" > /tmp/stack.txt; \
    pip check 2>&1 | norm > /tmp/check.before; \
    unmet="$(python -c "import importlib.metadata as md; \
        from packaging.requirements import Requirement as R; \
        from packaging.utils import canonicalize_name as cn; \
        have = {cn(d.metadata['Name']): d.version for d in md.distributions() if d.metadata['Name']}; \
        print(' '.join(r.name + str(r.specifier) for r in map(R, md.requires('vllm') or []) \
            if (r.marker is None or r.marker.evaluate({'extra': ''})) \
            and not (cn(r.name) in have and r.specifier.contains(have[cn(r.name)], prereleases=True))))")"; \
    extra=""; \
    pip show -q instanttensor 2>/dev/null || extra="instanttensor"; \
    if pip show -q opentelemetry-exporter-prometheus 2>/dev/null; then extra="$extra opentelemetry-exporter-prometheus"; fi; \
    echo "Re-resolving unmet vLLM requirements: ${unmet:-none}"; \
    pip install --no-cache-dir -c /tmp/stack.txt $unmet $extra lm_eval 'lm_eval[api]' inspect_ai inspect_evals; \
    pc="$(pip check 2>&1 || true)"; echo "$pc"; \
    new="$(echo "$pc" | norm | comm -13 /tmp/check.before -)"; \
    if echo "$new" | grep -iE "$stack"; then \
        echo "ERROR: the eval install added the vLLM-stack conflicts above" >&2; exit 1; \
    fi; \
    pip list --format=freeze | grep -iE "^$stack" | diff /tmp/stack.txt - \
        || { echo "ERROR: the eval install moved a vLLM-stack package (diff above)" >&2; exit 1; }; \
    rm -f /tmp/stack.txt /tmp/check.before

# Optional: pin vLLM to a specific upstream dev commit that has no released
# image yet (e.g. a fix that landed after the last vLLM tag). Point
# VLLM_WHEEL_URL at the immutable per-commit wheel from
# https://wheels.vllm.ai/<full-sha>/... and VLLM_WHEEL_SHA256 at its checksum.
# Both must be set together or the build fails — we never install an unpinned
# wheel (mirrors the wireproxy pinning). Installed --no-deps so the base's
# torch/xformers stack and the flashinfer pinned above are preserved: only
# coherent when the target commit shares the base's torch pin (verify) and
# FLASHINFER_VERSION matches the commit's pin. Unset for release builds — no-op.
# The wheel is saved under its REAL filename (decoding %2B -> +): pip derives the
# package/version from the filename, so a generic /tmp/vllm.whl is rejected as a
# malformed wheel name. The post-install gate runs `pip check` but only fails on
# vLLM-stack conflicts the overlay ADDS relative to the pre-install `pip check`
# — the base itself is not pip-check clean (see the eval step above). Versions
# on the left of "has requirement" are stripped before comparing, so the
# overlaid vLLM's new version alone doesn't count as a new conflict.
ARG VLLM_WHEEL_URL=""
ARG VLLM_WHEEL_SHA256=""
RUN if [ -n "${VLLM_WHEEL_URL}${VLLM_WHEEL_SHA256}" ]; then \
        if [ -z "$VLLM_WHEEL_URL" ] || [ -z "$VLLM_WHEEL_SHA256" ]; then \
            echo "ERROR: set BOTH VLLM_WHEEL_URL and VLLM_WHEEL_SHA256, or neither" >&2; exit 1; \
        fi; \
        whl="/tmp/$(basename "$VLLM_WHEEL_URL" | sed 's/%2[bB]/+/g')" \
        && curl -fSL -o "$whl" "$VLLM_WHEEL_URL" \
        && echo "${VLLM_WHEEL_SHA256}  ${whl}" | sha256sum -c - \
        && stack='(torch|pytorch[-_]triton|triton|vllm|flashinfer|xformers|nvidia[-_]|cuda[-_]|aiter|amd[-_]quark|rocm)' \
        && pip check 2>&1 | sed -E 's/^([^ ]+) [^ ]+ has requirement/\1 has requirement/' | sort > /tmp/check.before \
        && pip install --no-cache-dir --no-deps "$whl" \
        && rm -f "$whl" \
        && pc="$(pip check 2>&1 || true)" && echo "$pc" \
        && new="$(echo "$pc" | sed -E 's/^([^ ]+) [^ ]+ has requirement/\1 has requirement/' | sort | comm -13 /tmp/check.before -)" \
        && rm -f /tmp/check.before \
        && { echo "$new" | grep -iE "$stack" \
                && { echo "ERROR: the vLLM overlay added the vLLM-stack conflicts above" >&2; exit 1; } \
                || true; } \
        && python -c "import importlib.metadata as m; print('vLLM pinned to', m.version('vllm'))"; \
    fi

# HF Hub is fully Xet-backed now: hf_transfer is deprecated and unused, and
# huggingface_hub auto-installs the hf-xet backend. HF_XET_HIGH_PERFORMANCE is
# the Xet equivalent of the old HF_HUB_ENABLE_HF_TRANSFER=1 fast-transfer flag.
ENV HF_XET_HIGH_PERFORMANCE=1

# No phoning home from inside the rental: vLLM otherwise reports usage stats
# (GPU type, model architecture, config) to stats.vllm.ai, and huggingface_hub
# sends telemetry. Serving is unaffected; an operator can re-enable either by
# overriding the var at container start.
ENV VLLM_NO_USAGE_STATS=1 \
    DO_NOT_TRACK=1 \
    HF_HUB_DISABLE_TELEMETRY=1

COPY --from=wireproxy-build /usr/local/bin/wireproxy /usr/local/bin/wireproxy
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
