# wg-vllm-bridge

## Overview

A Docker image, deployable on unprivileged GPU containers from compute / GPU rental providers, that runs **vLLM** and **sshd** locally and exposes selected ports to a **WireGuard** network — without requiring `CAP_NET_ADMIN` or a kernel TUN device.

Built on top of an upstream vLLM runtime image — either `vllm/vllm-openai:vX.Y.Z` (CUDA) or `vllm/vllm-openai-rocm:nightly-<sha>` (ROCm). The Dockerfile is parameterized via `ARG BASE_IMAGE` and `ARG ACCEL={cuda,rocm}`; CI builds both streams. Bundles `wireproxy` (userspace WireGuard via `wireguard-go` + gVisor netstack) to terminate WG entirely in user-mode. vLLM binds loopback only; the only ingress through WG is the set of ports listed in `LISTEN_PORTS`, each forwarded to `127.0.0.1:<same-port>`. sshd binds `0.0.0.0:22` to also be reachable via the platform's port-mapping (out-of-band escape hatch if WG breaks).

## Why This Exists

Compute / GPU rental providers typically rent unprivileged containers that grant only the default Docker capability set (no `CAP_NET_ADMIN`). Kernel WireGuard, `wg-quick`, and `wireguard-go` with a TUN device all need that capability and don't run there. We need an inbound path from a private WG concentrator to a vLLM endpoint running inside the rental.

`wireproxy` solves this by running the entire WG dataplane in userspace via gVisor netstack, with `[TCPServerTunnel]` blocks that accept inbound TCP on the WG-side virtual interface and forward each connection to a local target. We render its config from env vars at container start — one `[TCPServerTunnel]` per port in `LISTEN_PORTS`, always with `Target = 127.0.0.1:<same-port>` — and supervise wireproxy alongside sshd and vLLM.

## Critical Rules

### NEVER Do

- **NEVER commit WG keys or API keys.** All secrets are env-var only. No config files, no `.env` files committed.
- **NEVER bake credentials into the image.** Everything sensitive is passed at container start.
- **NEVER bind vLLM to `0.0.0.0`.** vLLM must listen on `127.0.0.1:8000` so the only WG-side ingress is through the explicit `LISTEN_PORTS` list. If a contributor changes this, the security model collapses.
- **NEVER enable SSH password authentication.** sshd is configured `PasswordAuthentication=no` + `PermitRootLogin=prohibit-password`. Pubkey only. If `SSH_PUBLIC_KEY` / `PUBLIC_KEY` is unset, the container must refuse to start.
- **NEVER auto-add a prefix to `WG_ADDRESS`.** Refuse to start if the prefix is missing. Guessing `/32` would let a misconfigured address silently match too much.
- **NEVER reuse a WG peer key across rentals.** Treat every container instance's key as single-use; revoke and rotate on teardown.
- **NEVER use floating image tags inside the Dockerfile.** The wireproxy release (`WIREPROXY_VERSION` + `WIREPROXY_SHA256`) is pinned. The vLLM base comes in via `ARG BASE_IMAGE` — CI always passes a fully-pinned reference (a semver tag for CUDA, a `@sha256:` digest for ROCm). The Dockerfile's default `BASE_IMAGE` exists only as a local-dev convenience; production tags must never inherit it.
- **NEVER weaken key validation or skip the wireproxy SHA256 check.** A wrong key or a tampered binary fails silently — verify in CI.

### ALWAYS Do

- **ALWAYS fail fast at startup on missing config.** The entrypoint must `exit 1` if any required env var is absent rather than starting a half-wired container.
- **ALWAYS log to stdout/stderr only.** No log files; the orchestrator handles persistence.
- **ALWAYS surface a generated `VLLM_API_KEY` loudly once at startup.** If we generated it, the operator needs to capture it from logs immediately.
- **ALWAYS encode the upstream vLLM base in our own tag.** For CUDA, the bridge tag carries the vLLM semver (`cuda-vX.Y.Z-N`) and CI derives `BASE_IMAGE` from it — they cannot drift. For ROCm, no semver-pinned runtime image exists upstream, so the bridge tag carries the build date (`rocm-nightly-YYYYMMDD-N`) and the resolved upstream digest is written into the image's OCI labels (`org.opencontainers.image.base.digest`). Drift between bridge and vLLM versions makes debugging harder.
- **ALWAYS keep wireproxy, sshd, and vLLM lifecycled together.** If any supervised process dies, the container exits. A bridge without a model (or vice versa) is not a degraded state — it's a misconfiguration. The one exception is when `VLLM_MODEL` is unset by design (manual-start workflow), in which case vLLM is simply not part of the supervised set.
- **ALWAYS force the WG-side and local-side ports to match.** Each `[TCPServerTunnel]` has `Target = 127.0.0.1:<same-port>`. Mixed mappings are not allowed; that's the deliberate constraint of the `LISTEN_PORTS` schema.

## Architecture

Single container, three supervised processes (vLLM optional):

                              ┌─────────────────────────────────────────┐
                              │ container (unprivileged GPU rental)     │
                              │                                         │
       WG packets             │  ┌──────────────────────────────────┐   │
       (UDP, outbound) ─────► │  │ wireproxy                        │   │
                              │  │ (wireguard-go + netstack,        │   │
                              │  │  userspace; no TUN)              │   │
                              │  └─────────────┬────────────────────┘   │
                              │                │                        │
                              │     accepts on WG-side, each port in    │
                              │     LISTEN_PORTS; forwards to same      │
                              │     port on 127.0.0.1                   │
                              │                │                        │
                              │                ▼                        │
                              │  ┌──────────────────────────────────┐   │
                              │  │ vLLM     (127.0.0.1:8000)        │   │
                              │  │ sshd     (0.0.0.0:22)            │   │
                              │  │ ...other local services...       │   │
                              │  └──────────────────────────────────┘   │
                              └─────────────────────────────────────────┘

- WG protocol I/O via `conn.NewDefaultBind()` inside wireproxy — plain UDP socket, no caps.
- Decoded packets enter gVisor's netstack as if they were native IP on a normal interface.
- One `[TCPServerTunnel]` block is rendered per port in `LISTEN_PORTS`; each accepts inbound TCP at `WG_ADDRESS:<port>` and proxies to `127.0.0.1:<port>`.
- sshd binds `0.0.0.0:22` separately from wireproxy — that's the deliberate escape hatch via the platform's port-mapping. The operator may also include `22` in `LISTEN_PORTS` to make SSH reachable over WG.

## Configuration

All via environment variables. No config files, no CLI flags beyond what the entrypoint passes through to vLLM.

### WireGuard (required)

| Var | Required | Default | Notes |
|---|---|---|---|
| `WG_PRIVATE_KEY` | yes | — | base64 (`wg genkey` format) |
| `WG_PEER_PUBLIC_KEY` | yes | — | concentrator's public key |
| `WG_ENDPOINT` | yes | — | `ip:port` of the WG concentrator |
| `WG_ADDRESS` | yes | — | this peer's WG address **with prefix** (e.g. `10.0.0.42/32`). Fails fast if the prefix is missing. |
| `LISTEN_PORTS` | yes | — | comma-separated TCP ports to expose on WG. Each is forwarded to the same port on `127.0.0.1` — e.g. `8000,22` exposes vLLM and SSH over WG. |
| `WG_ALLOWED_IPS` | no | `0.0.0.0/0` | peer's allowed-source-IPs |
| `WG_KEEPALIVE` | no | `3` | `PersistentKeepalive` seconds |
| `WG_MTU` | no | `1400` | netstack MTU |
| `WG_PRESHARED_KEY` | no | — | optional PSK |
| `WG_VERBOSE` | no | unset | any non-empty value runs wireproxy without `-s`, restoring its full verbose output (useful for handshake debugging). Default is silent. |

### SSH (required — sshd is always on)

| Var | Required | Default | Notes |
|---|---|---|---|
| `SSH_PUBLIC_KEY` | yes\* | — | authorized public key written to `/root/.ssh/authorized_keys`. Pubkey auth only. |
| `PUBLIC_KEY` | yes\* | — | alias for compatibility with provider conventions that use this name; consulted if `SSH_PUBLIC_KEY` is unset. |

\*Exactly one of `SSH_PUBLIC_KEY` or `PUBLIC_KEY` must be set; container refuses to start otherwise.

### vLLM (optional auto-start)

| Var | Required | Default | Notes |
|---|---|---|---|
| `VLLM_MODEL` | no | — | if set, container auto-starts `vllm serve <model>` |
| `VLLM_API_KEY` | no | generated | if unset, generated via `openssl rand -hex 32` and logged once |
| `VLLM_EXTRA_ARGS` | no | — | extra args passed verbatim to `vllm serve` (word-split) |

If `VLLM_MODEL` is unset, only wireproxy + sshd run and vLLM must be started manually (e.g. via SSH) on `127.0.0.1:8000`.

The env-var contract is the public API of this image. Renaming or removing a variable is a breaking change for any downstream provider templates that consume it.

## Building

Two parallel streams, one per accelerator. CI workflows live in `.github/workflows/build-cuda.yml` and `.github/workflows/build-rocm.yml` — each triggers on its own git tag prefix and pushes its own set of image tags.

### CUDA — tag scheme `cuda-v<vllm-version>-<N>`

- Push a git tag like `cuda-v0.21.0-1`, `cuda-v0.21.0-2`, …
- CI derives `BASE_IMAGE=vllm/vllm-openai:vX.Y.Z` directly from the tag — they cannot drift.
- CI pushes three image tags per build:
  - `ghcr.io/tomaskir/vllm-wg-dockerized:cuda-vX.Y.Z-N` — **immutable** per-build artifact; pin here for reproducibility.
  - `ghcr.io/tomaskir/vllm-wg-dockerized:cuda-vX.Y.Z` — **floats** to the newest `-N` for that vLLM version on CUDA.
  - `ghcr.io/tomaskir/vllm-wg-dockerized:latest-cuda` — **floats** to the newest CUDA build overall.
- When upgrading vLLM: just push the new tag (`cuda-v0.21.1-1`). No Dockerfile change.

### ROCm — tag scheme `rocm-nightly-<YYYYMMDD>-<N>`

- Push a git tag like `rocm-nightly-20260527-1`, `rocm-nightly-20260527-2`, …
- Upstream does not yet publish semver-pinned ROCm runtime images — only `vllm/vllm-openai-rocm:nightly` (a moving target). CI resolves `nightly` to a concrete digest at build time and pins via `BASE_IMAGE=vllm/vllm-openai-rocm@sha256:<digest>`, then writes that digest into the image's OCI labels (`org.opencontainers.image.base.digest`) so the build is reproducible at the artifact level and the upstream snapshot is traceable.
- CI pushes two image tags per build:
  - `ghcr.io/tomaskir/vllm-wg-dockerized:rocm-nightly-YYYYMMDD-N` — **immutable** per-build artifact; pin here for reproducibility.
  - `ghcr.io/tomaskir/vllm-wg-dockerized:latest-rocm` — **floats** to the newest ROCm build overall.
- No per-version floating tag (the upstream has no version yet to float against).

### Both streams

Never overwrite an existing `-N` tag. If you need to roll back, push a new `-N` that reverts; don't force-push the old one.

To upgrade wireproxy: bump `WIREPROXY_VERSION` and `WIREPROXY_SHA256` in the Dockerfile (both must change together — leaving one stale will either fail the checksum or silently fetch the old binary). A wireproxy bump affects both streams; bump `-N` on both next time you tag.

To upgrade the `vllm/vllm-openai-rocm` base for ROCm: nothing to change — every build re-resolves `nightly` to whatever digest is current. To freeze ROCm to a specific historical nightly, pass `BASE_IMAGE` explicitly to a local build instead of relying on CI's auto-resolution.

## Operational Context

Typical flow on a compute / GPU rental provider:

1. Operator generates a fresh WG keypair per rental (`wg genkey | tee priv | wg pubkey > pub`).
2. Operator adds the public half as a `[Peer]` on the concentrator with a tightly-scoped `AllowedIPs`.
3. Operator launches an instance against this image, passing all `WG_*` env vars, `SSH_PUBLIC_KEY` (or `PUBLIC_KEY`), `LISTEN_PORTS` (e.g. `8000,22`), and optionally `VLLM_MODEL`.
4. Container starts: entrypoint validates env, renders `/etc/wireproxy.conf` (one `[TCPServerTunnel]` per port), installs authorized key, regenerates ssh host keys, starts wireproxy + sshd in background, generates/logs `VLLM_API_KEY`, starts vLLM (if `VLLM_MODEL` set) on `127.0.0.1:8000`.
5. Other peers on the WG network reach exposed services via `<WG_ADDRESS>:<port>` for each port in `LISTEN_PORTS`. The vLLM OpenAI API is at `http://<WG_ADDRESS>:8000/v1` with the surfaced key.
6. Operator captures `VLLM_API_KEY` from container logs immediately after start.
7. Operator SSHes via the provider's port-mapping endpoint OR via WG if `22` is in `LISTEN_PORTS`.
8. On rental teardown: operator deletes the peer entry from the concentrator and treats both the WG key and any generated API key as compromised.

## Code Style

- `entrypoint.sh` uses `set -euo pipefail`. Pass shellcheck before committing.
- Bash, not Python — the entrypoint is config rendering + process supervision, nothing more.
- Comments only where the WHY is non-obvious (wireproxy's `/32` Address requirement, `VLLM_EXTRA_ARGS` unquoted for word-splitting, process-supervision pattern).

## Testing

Currently manual. Suggested progression:

1. Local build smoke: `docker build .` succeeds; image runs and entrypoint fails fast when required env vars are absent.
2. End-to-end on a known concentrator: launch the image with WG env vars only, verify wireproxy comes up and a peer can reach `<WG_ADDRESS>:<LISTEN_PORT>` (use a stand-in target service, no GPU required).
3. Full GPU smoke on a real provider rental: launch with `VLLM_MODEL`, verify a peer can hit the OpenAI API end-to-end with the generated key.

## Upstream References

- wireproxy: https://github.com/windtf/wireproxy
- vLLM (OpenAI server): https://github.com/vllm-project/vllm
- wireguard-go netstack backend: https://github.com/WireGuard/wireguard-go/tree/master/tun/netstack

## License

MIT.
