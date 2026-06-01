# wg-vllm-bridge

This is an unprivileged GPU container running vLLM (typical on compute / GPU rental providers), exposed to a private WireGuard network - no `CAP_NET_ADMIN`, no kernel TUN.

The image extends an upstream vLLM runtime image (CUDA or ROCm) and adds [wireproxy](https://github.com/windtf/wireproxy) to terminate WireGuard entirely in userspace. vLLM binds loopback only; the WG-side ingress is the explicit list of ports in `LISTEN_PORTS`, each forwarded to the same port on `127.0.0.1`. sshd also runs (always) and binds `0.0.0.0:22` so it's reachable via the platform's port-mapping as an out-of-band escape hatch.

Two parallel image streams are published, one per accelerator:

- **CUDA** — extends `vllm/vllm-openai:vX.Y.Z`. Tags: `latest-cuda`, `cuda-vX.Y.Z`, `cuda-vX.Y.Z-N`.
- **ROCm** — extends `vllm/vllm-openai-rocm:vX.Y.Z`. Tags: `latest-rocm`, `rocm-vX.Y.Z`, `rocm-vX.Y.Z-N`.

## Quick start

```bash
# 1. Generate a fresh keypair for this rental
wg genkey | tee priv | wg pubkey > pub

# 2. On your WG concentrator, add a [Peer] block with the contents of `pub`
#    and a tightly-scoped AllowedIPs (e.g. 10.0.0.42/32)

# 3. Launch the container
docker run --gpus all --rm \
  -e WG_PRIVATE_KEY="$(cat priv)" \
  -e WG_PEER_PUBLIC_KEY="<concentrator-public-key>" \
  -e WG_ENDPOINT="<concentrator-ip>:51820" \
  -e WG_ADDRESS="10.0.0.42/32" \
  -e LISTEN_PORTS="8000,22" \
  -e SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)" \
  -e VLLM_MODEL="meta-llama/Llama-3.1-8B-Instruct" \
  ghcr.io/tomaskir/vllm-wg-dockerized:latest-cuda
```

Usually the container would be launched by your compute / GPU rental provider's platform.

Capture the generated `VLLM_API_KEY` from the container logs on first start. Other peers on the WG network reach the OpenAI API at `http://10.0.0.42:8000/v1` (example) using that key.

`WG_ADDRESS` must include a prefix (/24, etc.) - if needed use `/32` for an IPv4 host address (`/128` for IPv6). The entrypoint refuses to guess.

`LISTEN_PORTS` is comma-separated; each port `N` becomes a wireproxy `[TCPServerTunnel]` with `ListenPort = N` and `Target = 127.0.0.1:N`. Use this to also expose SSH (`22`) or anything else you start inside the container.

**Image tags.** `:latest-cuda` / `:latest-rocm` float to the newest build of each accelerator. `:cuda-vX.Y.Z` floats to the newest build of that vLLM version on CUDA. For reproducible deployments, pin to an immutable per-build tag like `:cuda-v0.22.0-1` or `:rocm-v0.22.0-1`. See [CLAUDE.md](./CLAUDE.md#building) for the full tag scheme.

## Env vars

See [CLAUDE.md](./CLAUDE.md#configuration) for the full table. Minimum required:

- `WG_PRIVATE_KEY`, `WG_PEER_PUBLIC_KEY`, `WG_ENDPOINT`, `WG_ADDRESS`, `LISTEN_PORTS`
- `SSH_PUBLIC_KEY` (or the alias `PUBLIC_KEY`, for compatibility with provider conventions that use that name)

Optional: `VLLM_MODEL` to auto-start serving, and `HF_TOKEN` if the model is gated or private (e.g. Llama). Both are passed at container start; never commit them.

## Building

```bash
# CUDA
docker build \
  --build-arg BASE_IMAGE=vllm/vllm-openai:v0.22.0 \
  --build-arg ACCEL=cuda \
  -t ghcr.io/tomaskir/vllm-wg-dockerized:cuda-v0.22.0-1 .

# ROCm
docker build \
  --build-arg BASE_IMAGE=vllm/vllm-openai-rocm:v0.22.0 \
  --build-arg ACCEL=rocm \
  -t ghcr.io/tomaskir/vllm-wg-dockerized:rocm-v0.22.0-1 .
```

## Security

- WG private keys and API keys are env-var only. Never commit.
- vLLM binds `127.0.0.1` - not reachable except through the WG bridge.
- sshd is pubkey-only (`PasswordAuthentication=no`, `PermitRootLogin=prohibit-password`).
- Rotate the WG peer key on every rental teardown.

## License

MIT.
