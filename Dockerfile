# syntax=docker/dockerfile:1.7

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
# Stage 2: final image extending vLLM
# --------------------------------------------------------------------
FROM vllm/vllm-openai:v0.21.0

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
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir flashinfer-jit-cache --index-url https://flashinfer.ai/whl/cu130
RUN pip install --no-cache-dir hf_transfer lm_eval
ENV HF_HUB_ENABLE_HF_TRANSFER=1

COPY --from=wireproxy-fetch /usr/local/bin/wireproxy /usr/local/bin/wireproxy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
