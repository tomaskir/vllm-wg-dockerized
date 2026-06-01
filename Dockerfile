# syntax=docker/dockerfile:1.7

# Global ARG: must be declared before the first FROM so it's in scope for the
# stage-2 `FROM ${BASE_IMAGE}`. ARGs declared between FROMs are stage-local
# and cannot be referenced by a subsequent FROM line.
# BASE_IMAGE selects the upstream vLLM runtime to extend:
#   - CUDA: vllm/vllm-openai:vX.Y.Z              (pin to a semver tag)
#   - ROCm: vllm/vllm-openai-rocm:nightly-<sha>  (no semver tags exist yet;
#          CI auto-resolves `nightly` to a digest and pins that)
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
# ACCEL gates accelerator-specific installs. The CUDA-only step is the
# flashinfer trio (python/cubin/jit-cache), wheel-published for CUDA only.
# All three are pinned to 0.6.11.post2 to match vLLM 0.22.0's own pin of
# flashinfer-python/cubin: the jit-cache AOT kernels must match the runtime
# flashinfer version, and an unpinned jit-cache would float ahead and drift.
# python/cubin are already base deps (this is a no-op that documents intent);
# jit-cache is the heavy ~1.8GB add and is NOT a default dep.
# NOTE: when bumping the vLLM base, re-check vLLM's flashinfer pin and update
# this version to match.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE}

ARG ACCEL=cuda

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

RUN if [ "$ACCEL" = "cuda" ]; then \
        pip install --no-cache-dir flashinfer-python==0.6.11.post2 flashinfer-cubin==0.6.11.post2 \
        && pip install --no-cache-dir flashinfer-jit-cache==0.6.11.post2 --index-url https://flashinfer.ai/whl/cu130; \
    fi
RUN pip install --no-cache-dir hf_transfer lm_eval 'lm_eval[api]' inspect_ai inspect_evals instanttensor
ENV HF_HUB_ENABLE_HF_TRANSFER=1

COPY --from=wireproxy-fetch /usr/local/bin/wireproxy /usr/local/bin/wireproxy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
