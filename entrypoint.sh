#!/bin/bash
set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-${RUNPOD_SECRET_TSAUTH_KEY:-}}"
if [ -z "${TS_AUTHKEY}" ]; then
  echo "FATAL: TS_AUTHKEY (or RunPod secret TSAUTH_KEY) is required — generate a fresh ephemeral key each run" >&2
  exit 1
fi
TS_HOSTNAME="${TS_HOSTNAME:-runpod-olmocr}"
# Optional long-lived admin authkey. The -N hostname dedup suffix (e.g.
# runpod-olmocr-5) appears whenever a stale node from a previous (terminated,
# never-cleaned-up) pod run is still registered in the tailnet under the same
# base hostname. With this set, the entrypoint deletes those stale nodes
# automatically before `tailscale up`; without it they must be removed by hand
# in the tailnet admin console.
TS_ADMIN_AUTHKEY="${TS_ADMIN_AUTHKEY:-${RUNPOD_SECRET_TSADMINAUTH_KEY:-}}"
# Port vLLM will actually bind to. Whatever --port is passed in the container
# command (the args below) MUST match this value, or tailscale serve will be
# proxying to the wrong port.
VLLM_PORT="${VLLM_PORT:-8000}"

if [ "$#" -eq 0 ]; then
  echo "FATAL: no vLLM arguments supplied — pass the model and flags (e.g. --served-model-name, --host, --port) as the RunPod container command" >&2
  exit 1
fi

TS_SOCKET=/var/run/tailscale/tailscaled.sock
mkdir -p /var/lib/tailscale /var/run/tailscale

echo "==> Starting tailscaled (userspace networking — RunPod pods aren't granted NET_ADMIN/TUN)"
tailscaled \
  --tun=userspace-networking \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket="${TS_SOCKET}" &

# `tailscale status` exits non-zero while logged out (NeedsLogin), by design —
# it answers "are we connected", not "is the daemon up". So check for the
# daemon's socket instead; it appears well before login state matters.
for i in $(seq 1 30); do
  [ -S "${TS_SOCKET}" ] && break
  if [ "$i" -eq 30 ]; then
    echo "FATAL: tailscaled did not become ready in time" >&2
    exit 1
  fi
  sleep 1
done

# Reap stale nodes BEFORE `tailscale up`, not after. Tailscale only appends a
# dedup suffix (-2, -3, -5, …) when another node already holds the base name, so
# the zombie has to be gone *before* we register — cleaning up afterwards leaves
# this boot stuck with its suffix and only helps the next one. With no persisted
# tailscaled state every run is a fresh identity, so any node still claiming
# TS_HOSTNAME at this point is stale by definition.
# Single-pod assumption: if a second pod is legitimately serving under the same
# TS_HOSTNAME, this deletes it. Give concurrent pods distinct TS_HOSTNAMEs.
if [ -n "${TS_ADMIN_AUTHKEY}" ]; then
  echo "==> Reaping stale nodes claiming '${TS_HOSTNAME}' before registering"
  # `-` means "the default tailnet for these credentials". API keys authenticate
  # as HTTP basic with an empty password. The list response is {"devices":[...]}
  # and its fields are lowercase (.id, .hostname) — unlike the CLI's status --json.
  STALE_IDS=$(curl -sf -u "${TS_ADMIN_AUTHKEY}:" \
    "https://api.tailscale.com/api/v2/tailnet/-/devices" | \
    jq -r --arg host "${TS_HOSTNAME}" \
    '.devices[] | select(.hostname == $host) | .id' || true)
  if [ -n "${STALE_IDS}" ]; then
    for STALE_ID in ${STALE_IDS}; do
      echo "==> Deleting stale node ${STALE_ID}"
      curl -sf -X DELETE -u "${TS_ADMIN_AUTHKEY}:" \
        "https://api.tailscale.com/api/v2/device/${STALE_ID}" >/dev/null \
        || echo "WARN: could not delete node ${STALE_ID}" >&2
    done
  else
    echo "==> No stale nodes claiming '${TS_HOSTNAME}'"
  fi
else
  echo "==> TS_ADMIN_AUTHKEY not set — skipping stale-node reap; expect a -N suffix if a zombie still holds '${TS_HOSTNAME}'"
fi

echo "==> Authenticating to tailnet as ${TS_HOSTNAME}"
if ! tailscale --socket="${TS_SOCKET}" up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME}" \
    --accept-dns=true; then
  echo "FATAL: tailscale up failed — authkey is likely invalid, expired, or already consumed" >&2
  exit 1
fi

# Report the name actually granted. `.Self.HostName` is the *suffix-free* base
# name and so always equals TS_HOSTNAME — comparing against it was the bug that
# made the old cleanup branch unreachable. `.Self.DNSName` carries the real name
# ("runpod-olmocr-3.<tailnet>.ts.net."), so take its first label.
ACTUAL_NAME=$(tailscale --socket="${TS_SOCKET}" status --json | jq -r '.Self.DNSName' | cut -d. -f1)
if [ "${ACTUAL_NAME}" != "${TS_HOSTNAME}" ]; then
  echo "WARN: registered as '${ACTUAL_NAME}', not '${TS_HOSTNAME}' — another node still held the base name." >&2
  echo "WARN: clients pointed at '${TS_HOSTNAME}' will NOT reach this pod. Set TS_ADMIN_AUTHKEY, or delete the zombie by hand." >&2
else
  echo "==> Live at hostname: ${ACTUAL_NAME}"
fi

# vLLM has no Host-header restriction (unlike Ollama's loopback-only
# allow-list — see the reference runpod-ai image), so `tailscale serve` can
# proxy straight to it. No local nginx Host-header-rewrite proxy needed here.
#
# Configure the proxy BEFORE starting vLLM: serve config doesn't require the
# backend to be up yet, and the olmOCR model download + vLLM startup can take
# 10+ minutes, which would otherwise leave the tailnet URL unavailable for the
# whole warm-up window.
DNS_NAME=$(tailscale --socket="${TS_SOCKET}" status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
echo "==> Configuring tailscale serve to proxy https://${DNS_NAME} -> http://127.0.0.1:${VLLM_PORT}"
if ! tailscale --socket="${TS_SOCKET}" serve --bg --https=443 "http://127.0.0.1:${VLLM_PORT}"; then
  echo "FATAL: tailscale serve failed to configure" >&2
  exit 1
fi
echo "==> vLLM will be reachable at: https://${DNS_NAME}/v1"

echo "==> Starting vllm serve (make sure --port in the container command matches VLLM_PORT=${VLLM_PORT})"
exec vllm serve "$@"
