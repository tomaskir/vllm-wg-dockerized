#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------------------------------
# Required env vars
# --------------------------------------------------------------------
required=(WG_PRIVATE_KEY WG_PEER_PUBLIC_KEY WG_ENDPOINT WG_ADDRESS LISTEN_PORTS)
missing=()
for var in "${required[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        missing+=("$var")
    fi
done
if (( ${#missing[@]} > 0 )); then
    echo "FATAL: missing required env vars: ${missing[*]}" >&2
    exit 1
fi

# WG_ADDRESS must include a prefix; wireproxy needs an explicit subnet.
# Refuse to guess so a misconfigured Address doesn't silently match too much.
if [[ "$WG_ADDRESS" != */* ]]; then
    echo "FATAL: WG_ADDRESS must include a prefix (ex. /24, or use ${WG_ADDRESS}/32 for IPv4 or ${WG_ADDRESS}/128 for IPv6 if needed)." >&2
    exit 1
fi

# SSH key: accept either SSH_PUBLIC_KEY (our name) or PUBLIC_KEY (Vast.ai convention)
SSH_AUTHORIZED_KEY="${SSH_PUBLIC_KEY:-${PUBLIC_KEY:-}}"
if [[ -z "$SSH_AUTHORIZED_KEY" ]]; then
    echo "FATAL: sshd is always enabled; set SSH_PUBLIC_KEY (or PUBLIC_KEY) to your authorized public key." >&2
    exit 1
fi

# --------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------
: "${WG_ALLOWED_IPS:=0.0.0.0/0}"
: "${WG_KEEPALIVE:=3}"
: "${WG_MTU:=1400}"

# --------------------------------------------------------------------
# Parse LISTEN_PORTS (comma-separated) and validate each entry
# --------------------------------------------------------------------
IFS=',' read -ra RAW_PORTS <<< "$LISTEN_PORTS"
PORTS=()
declare -A seen_ports
for raw in "${RAW_PORTS[@]}"; do
    port="${raw// /}"
    [[ -z "$port" ]] && continue
    # {1,5} bounds the digits so 10# arithmetic below can't overflow; 10# forces
    # decimal, since bash arithmetic reads leading-zero values as octal.
    if ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
        echo "FATAL: invalid port in LISTEN_PORTS: '$port'" >&2
        exit 1
    fi
    port=$((10#$port))
    if (( port < 1 || port > 65535 )); then
        echo "FATAL: invalid port in LISTEN_PORTS: '$port'" >&2
        exit 1
    fi
    # Dedupe: a repeated port would render two [TCPServerTunnel] blocks.
    [[ -n "${seen_ports[$port]:-}" ]] && continue
    seen_ports[$port]=1
    PORTS+=("$port")
done
if (( ${#PORTS[@]} == 0 )); then
    echo "FATAL: LISTEN_PORTS contained no usable ports." >&2
    exit 1
fi

# --------------------------------------------------------------------
# vLLM API key: use if provided, otherwise generate and surface once
# --------------------------------------------------------------------
if [[ -z "${VLLM_API_KEY:-}" ]]; then
    VLLM_API_KEY="$(openssl rand -hex 32)"
    echo "================================================================"
    echo " Generated VLLM_API_KEY: ${VLLM_API_KEY}"
    echo " (capture this from container logs; it will not be reprinted)"
    echo "================================================================"
fi
export VLLM_API_KEY

# --------------------------------------------------------------------
# Render wireproxy config
# --------------------------------------------------------------------
WIREPROXY_CONF=/etc/wireproxy.conf
umask 077
{
    echo "[Interface]"
    echo "PrivateKey = ${WG_PRIVATE_KEY}"
    echo "Address = ${WG_ADDRESS}"
    echo "MTU = ${WG_MTU}"
    echo ""
    echo "[Peer]"
    echo "PublicKey = ${WG_PEER_PUBLIC_KEY}"
    if [[ -n "${WG_PRESHARED_KEY:-}" ]]; then
        echo "PresharedKey = ${WG_PRESHARED_KEY}"
    fi
    echo "AllowedIPs = ${WG_ALLOWED_IPS}"
    echo "Endpoint = ${WG_ENDPOINT}"
    echo "PersistentKeepalive = ${WG_KEEPALIVE}"
    for port in "${PORTS[@]}"; do
        echo ""
        echo "[TCPServerTunnel]"
        echo "ListenPort = ${port}"
        echo "Target = 127.0.0.1:${port}"
    done
} > "$WIREPROXY_CONF"
umask 022

# Validate the rendered config before touching anything else. wireproxy's
# configtest is the only thing that actually checks the WG keys (base64 form and
# 32-byte length) and the endpoint; without it a bad key surfaces only after
# authorized_keys, fresh host keys and sshd are already in place — a half-wired
# container. Note it does NOT catch a missing Address prefix (it reports
# "Config OK"), which is why the explicit WG_ADDRESS check above stays.
if ! wireproxy_check="$(wireproxy -n -c "$WIREPROXY_CONF" 2>&1)"; then
    echo "FATAL: wireproxy rejected the rendered config: ${wireproxy_check}" >&2
    exit 1
fi

# --------------------------------------------------------------------
# SSH setup
# --------------------------------------------------------------------
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
printf '%s\n' "$SSH_AUTHORIZED_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null

# --------------------------------------------------------------------
# GPU preflight: warn only, never exit — the manual-start workflow (no
# VLLM_MODEL) must still come up, and these hosts may be fixable over SSH.
# --------------------------------------------------------------------
gpu_count=0
if command -v nvidia-smi >/dev/null 2>&1 \
        && driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)" \
        && [[ -n "$driver" ]]; then
    gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
    # Minimum drivers: CUDA 13.x needs >= 580; CUDA 12.x runs on >= 525 via
    # minor-version compatibility. Too old a driver otherwise surfaces only as
    # an opaque CUDA init error deep inside vLLM.
    cuda_major="${CUDA_VERSION:-}"; cuda_major="${cuda_major%%.*}"
    min_driver=""
    case "$cuda_major" in
        13) min_driver=580 ;;
        12) min_driver=525 ;;
    esac
    driver_major="${driver%%.*}"
    if [[ -n "$min_driver" && "$driver_major" =~ ^[0-9]+$ ]] && (( driver_major < min_driver )) \
            && [[ "${VLLM_ENABLE_CUDA_COMPATIBILITY:-0}" != 1 ]]; then
        echo "WARNING: NVIDIA driver ${driver} is older than ${min_driver}, the minimum for this image's CUDA ${CUDA_VERSION}." >&2
        echo "WARNING: on datacenter GPUs set VLLM_ENABLE_CUDA_COMPATIBILITY=1 (the image ships CUDA forward-compat libs); consumer GPUs need a newer host driver." >&2
    fi
elif [[ -e /dev/kfd ]]; then
    gpu_count="$(find /dev/dri -maxdepth 1 -name 'renderD*' 2>/dev/null | wc -l || true)"
fi

# Docker's default /dev/shm is 64 MiB. vLLM's multi-GPU workers and NCCL use it
# for intra-node transfers, and a tiny one crashes tensor-parallel runs with
# bus errors.
shm_kib="$(df -k --output=size /dev/shm 2>/dev/null | tail -n1 | tr -d ' ' || true)"
if (( gpu_count > 1 )) && [[ "$shm_kib" =~ ^[0-9]+$ ]] && (( shm_kib < 1048576 )); then
    echo "WARNING: /dev/shm is only $(( shm_kib / 1024 )) MiB with ${gpu_count} GPUs visible; multi-GPU vLLM needs more. Launch with --ipc=host or --shm-size=16g." >&2
fi

# --------------------------------------------------------------------
# Process supervision: start wireproxy, sshd, and optionally vLLM.
# Container exits as soon as any supervised process exits.
# --------------------------------------------------------------------
declare -A pids
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
    for name in "${!pids[@]}"; do
        pid="${pids[$name]}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    # Wait for children to exit so vLLM gets the runtime's stop grace period
    # to drain; PID 1 exiting would kill the namespace outright.
    wait
}
trap cleanup EXIT INT TERM

echo "Starting wireproxy: WG ${WG_ADDRESS}, exposing ports ${PORTS[*]} (loopback targets)"
# wireproxy only ships verbose (default) and silent (-s); no "info" level.
# Default to silent; WG_VERBOSE restores full verbose output for handshake debugging.
if [[ -n "${WG_VERBOSE:-}" ]]; then
    wireproxy -c "$WIREPROXY_CONF" &
else
    wireproxy -s -c "$WIREPROXY_CONF" &
fi
pids[wireproxy]=$!

echo "Starting sshd: 0.0.0.0:22 (pubkey auth only)"
/usr/sbin/sshd -D -e \
    -o PermitRootLogin=prohibit-password \
    -o PasswordAuthentication=no \
    -o PubkeyAuthentication=yes &
pids[sshd]=$!

if [[ -n "${VLLM_MODEL:-}" ]]; then
    echo "Starting vLLM: model=${VLLM_MODEL} bind=127.0.0.1:8000"
    # The API key is passed via the exported VLLM_API_KEY env var, NOT --api-key:
    # vLLM resolves `args.api_key or [envs.VLLM_API_KEY]`, so both are equivalent,
    # but an argv flag would expose the key in `ps` to anything running in the
    # container. VLLM_EXTRA_ARGS intentionally unquoted to allow word-splitting
    # shellcheck disable=SC2086
    vllm serve "$VLLM_MODEL" \
        --host 127.0.0.1 \
        --port 8000 \
        ${VLLM_EXTRA_ARGS:-} &
    pids[vllm]=$!
else
    echo "VLLM_MODEL unset; running wireproxy + sshd only. Start vLLM manually on 127.0.0.1:8000."
fi

exit_status=0
wait -n || exit_status=$?
echo "A supervised process exited with status ${exit_status}; tearing down container."
exit "$exit_status"
