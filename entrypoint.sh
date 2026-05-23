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
for raw in "${RAW_PORTS[@]}"; do
    port="${raw// /}"
    [[ -z "$port" ]] && continue
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "FATAL: invalid port in LISTEN_PORTS: '$port'" >&2
        exit 1
    fi
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

# --------------------------------------------------------------------
# SSH setup
# --------------------------------------------------------------------
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
printf '%s\n' "$SSH_AUTHORIZED_KEY" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A >/dev/null

# --------------------------------------------------------------------
# Process supervision: start wireproxy, sshd, and optionally vLLM.
# Container exits as soon as any supervised process exits.
# --------------------------------------------------------------------
declare -A pids
cleanup() {
    for name in "${!pids[@]}"; do
        pid="${pids[$name]}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT INT TERM

echo "Starting wireproxy: WG ${WG_ADDRESS}, exposing ports ${PORTS[*]} (loopback targets)"
wireproxy -c "$WIREPROXY_CONF" &
pids[wireproxy]=$!

echo "Starting sshd: 0.0.0.0:22 (pubkey auth only)"
/usr/sbin/sshd -D -e \
    -o PermitRootLogin=prohibit-password \
    -o PasswordAuthentication=no \
    -o PubkeyAuthentication=yes &
pids[sshd]=$!

if [[ -n "${VLLM_MODEL:-}" ]]; then
    echo "Starting vLLM: model=${VLLM_MODEL} bind=127.0.0.1:8000"
    # VLLM_EXTRA_ARGS intentionally unquoted to allow word-splitting
    # shellcheck disable=SC2086
    vllm serve "$VLLM_MODEL" \
        --host 127.0.0.1 \
        --port 8000 \
        --api-key "$VLLM_API_KEY" \
        ${VLLM_EXTRA_ARGS:-} &
    pids[vllm]=$!
else
    echo "VLLM_MODEL unset; running wireproxy + sshd only. Start vLLM manually on 127.0.0.1:8000."
fi

exit_status=0
wait -n || exit_status=$?
echo "A supervised process exited with status ${exit_status}; tearing down container."
exit "$exit_status"
