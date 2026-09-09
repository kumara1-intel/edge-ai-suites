#!/bin/bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Runs the Traffic Intersection Agent as an OpenShell sandbox pod inside the same
# Kubernetes cluster as the Helm release deployed with `openshell.enabled=true` (see
# values.yaml), via a --gateway already registered with the CLI using a
# Kubernetes/Agent-Sandbox compute driver (install the gateway's Helm chart and
# register it with `openshell gateway add` before running this script).
# The sandbox reaches OVMS/Metrics Manager via ClusterIP Service DNS. The MQTT broker
# (a separate "Smart Intersection" release) must expose a plaintext WebSocket listener
# (OpenShell's L7 proxy cannot inspect TLS) — pass its address via --mqtt-host/--mqtt-ws-port.
#
# Usage:
#   ./openshell-sandbox.sh up   --mqtt-host broker.default.svc.cluster.local --mqtt-ws-port 1885 [--release stia] [--namespace default] [--gateway kubernetes]
#   ./openshell-sandbox.sh down [--release stia] [--namespace default] [--gateway kubernetes]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

RELEASE="stia"
NAMESPACE="default"
BACKEND_PORT="8081"
UI_PORT="7860"
GATEWAY="kubernetes"
MQTT_HOST=""
MQTT_WS_PORT=""

usage() {
    cat <<EOF
Usage: $0 <up|down> [options]

Options:
  --release NAME        Helm release name (default: stia)
  --namespace NS        Kubernetes namespace the release is installed in (default: default)
  --backend-port PORT   Local port to forward the agent API to (default: 8081)
  --ui-port PORT        Local port to forward the agent UI to (default: 7860)
  --gateway NAME        OpenShell gateway registered with a Kubernetes compute driver (default: kubernetes)
  --mqtt-host HOST      Address (Service DNS name or IP) of the broker's plaintext WebSocket listener (required for 'up')
  --mqtt-ws-port PORT   Port of the broker's plaintext WebSocket listener (required for 'up')
EOF
}

log() { echo -e "${BLUE}==> $*${NC}"; }
err() { echo -e "${RED}ERROR: $*${NC}" >&2; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "$1 is required but not found in PATH."
        exit 1
    fi
}

sandbox_name() {
    echo "stia-$(printf '%s-%s' "$RELEASE" "$NAMESPACE" | tr '[:upper:]_' '[:lower:]-' | cut -c1-30)"
}

# ClusterIP Service port (by name) for a service in the release's namespace — not a
# NodePort, since the sandbox pod lives in-cluster and can reach ClusterIP directly.
service_port() {
    local service="$1" port_name="$2"
    kubectl get svc "$service" -n "$NAMESPACE" \
        -o jsonpath="{.spec.ports[?(@.name==\"${port_name}\")].port}"
}

# Read the model name/device/weight-format actually configured for this release's OVMS
# subchart, so the sandboxed agent computes the same OVMS-registered model id at runtime
# (see VLMService._compute_ovms_model_name in src/services/vlm_service.py).
ovms_value() {
    helm get values -a "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('ovms',{}).get('env',{}).get(sys.argv[1],''))" "$1"
}

# Read a top-level.nested value (dot-separated path) from the release's effective values.
chart_value() {
    helm get values -a "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
for key in sys.argv[1].split('.'):
    d = d.get(key, {}) if isinstance(d, dict) else ''
print(d if isinstance(d, str) else (d if not isinstance(d, dict) else ''))
" "$1"
}

up() {
    require_cmd openshell
    require_cmd kubectl
    require_cmd helm
    require_cmd python3

    if [ -z "$MQTT_HOST" ] || [ -z "$MQTT_WS_PORT" ]; then
        err "--mqtt-host and --mqtt-ws-port are required (broker's plaintext WebSocket listener)."
        exit 1
    fi

    if ! openshell -g "$GATEWAY" status >/dev/null 2>&1; then
        err "OpenShell gateway '${GATEWAY}' is not reachable. Install/register a Kubernetes-driver gateway first."
        exit 1
    fi

    local ovms_port metrics_port ovms_addr metrics_addr
    ovms_addr="${RELEASE}-ovms.${NAMESPACE}.svc.cluster.local"
    metrics_addr="${RELEASE}-metrics-manager.${NAMESPACE}.svc.cluster.local"

    ovms_port=$(service_port "${RELEASE}-ovms" "http")
    if [ -z "$ovms_port" ]; then
        err "Could not find a Service port named 'http' on '${RELEASE}-ovms' in namespace '${NAMESPACE}'. Is the release installed?"
        exit 1
    fi

    metrics_port=$(service_port "${RELEASE}-metrics-manager" "metrics")
    if [ -z "$metrics_port" ]; then
        err "Could not find a Service port named 'metrics' on '${RELEASE}-metrics-manager' in namespace '${NAMESPACE}'. Is the release installed?"
        exit 1
    fi

    local vlm_model vlm_device vlm_weight_format vlm_max_tokens
    vlm_model=$(ovms_value modelName)
    vlm_device=$(ovms_value targetDevice)
    vlm_weight_format=$(ovms_value weightFormat)
    vlm_max_tokens=$(ovms_value maxCompletionTokens)
    if [ -z "$vlm_model" ]; then
        err "Could not read ovms.env.modelName from release '${RELEASE}' values (helm get values). Is the release installed?"
        exit 1
    fi

    local intersection_name intersection_lat intersection_lon weather_mock density_threshold
    intersection_name=$(chart_value intersection.name)
    intersection_lat=$(chart_value intersection.latitude)
    intersection_lon=$(chart_value intersection.longitude)
    weather_mock=$(chart_value env.weatherMock)
    density_threshold=$(chart_value traffic.highDensityThreshold)

    local sandbox agent_image
    sandbox=$(sandbox_name)
    agent_image="${REGISTRY:-}smart-traffic-intersection-agent:${TAG:-latest}"

    openshell -g "$GATEWAY" sandbox delete "$sandbox" >/dev/null 2>&1 || true

    log "Creating OpenShell sandbox '$sandbox' (gateway '$GATEWAY', pod in namespace '$NAMESPACE') for release '$RELEASE'..."
    if ! openshell -g "$GATEWAY" sandbox create \
        --name "$sandbox" \
        --from "$agent_image" \
        --env "VLM_BASE_URL=http://${ovms_addr}:${ovms_port}" \
        --env "METRICS_MANAGER_URL=http://${metrics_addr}:${metrics_port}" \
        --env "METRICS_STREAM_URL=http://${metrics_addr}:${metrics_port}/metrics/stream" \
        --env "METRICS_HEALTH_URL=http://${metrics_addr}:${metrics_port}/health" \
        --env "VLM_MODEL_NAME=${vlm_model}" \
        --env "VLM_TARGET_DEVICE=${vlm_device:-CPU}" \
        --env "VLM_WEIGHT_FORMAT=${vlm_weight_format:-}" \
        --env "VLM_TIMEOUT_SECONDS=${VLM_TIMEOUT_SECONDS:-1800}" \
        --env "VLM_MAX_COMPLETION_TOKENS=${vlm_max_tokens:-}" \
        --env "VLM_TEMPERATURE=${VLM_TEMPERATURE:-}" \
        --env "VLM_TOP_P=${VLM_TOP_P:-}" \
        --env "USE_API=true" \
        --env "LOG_LEVEL=${LOG_LEVEL:-INFO}" \
        --env "MQTT_HOST=${MQTT_HOST}" \
        --env "MQTT_PORT=${MQTT_WS_PORT}" \
        --env "MQTT_TRANSPORT=websockets" \
        --env "MQTT_USE_TLS=false" \
        --env "INTERSECTION_NAME=${intersection_name}" \
        --env "INTERSECTION_LATITUDE=${intersection_lat}" \
        --env "INTERSECTION_LONGITUDE=${intersection_lon}" \
        --env "WEATHER_MOCK=${weather_mock:-false}" \
        --env "HIGH_DENSITY_THRESHOLD=${density_threshold:-10}" \
        --no-tty -- true; then
        exit 1
    fi

    log "Applying network policy (OVMS/Metrics/MQTT reached via in-cluster Service DNS)..."
    openshell -g "$GATEWAY" policy update "$sandbox" \
        --add-endpoint "${MQTT_HOST}:${MQTT_WS_PORT}:read-write:websocket:enforce" \
        --add-endpoint "${ovms_addr}:${ovms_port}:read-write:rest:enforce" \
        --add-endpoint "${metrics_addr}:${metrics_port}:read-write:rest:enforce" \
        --binary /usr/local/bin/python \
        --wait

    log "Starting the agent inside the sandbox..."
    nohup openshell -g "$GATEWAY" sandbox exec -n "$sandbox" -- \
        bash -lc 'export PATH=/app/.venv/bin:$PATH; cd /app && exec bash docker-entrypoint.sh' \
        > "$(dirname "${BASH_SOURCE[0]}")/.openshell-sandbox-traffic-agent.log" 2>&1 &

    openshell -g "$GATEWAY" forward start --background "$BACKEND_PORT" "$sandbox"
    openshell -g "$GATEWAY" forward start --background "$UI_PORT" "$sandbox"

    echo -e "${GREEN}Traffic Intersection Agent running as OpenShell sandbox '$sandbox'.${NC}"
    echo -e "${CYAN}Access API Docs -> http://localhost:${BACKEND_PORT}/docs${NC}"
    echo -e "${CYAN}Access UI        -> http://localhost:${UI_PORT}${NC}"
}

down() {
    require_cmd openshell
    local sandbox
    sandbox=$(sandbox_name)
    openshell -g "$GATEWAY" sandbox delete "$sandbox" >/dev/null 2>&1 || true
    echo -e "${YELLOW}Deleted OpenShell sandbox '$sandbox'.${NC}"
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --backend-port) BACKEND_PORT="$2"; shift 2 ;;
        --ui-port) UI_PORT="$2"; shift 2 ;;
        --gateway) GATEWAY="$2"; shift 2 ;;
        --mqtt-host) MQTT_HOST="$2"; shift 2 ;;
        --mqtt-ws-port) MQTT_WS_PORT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

case "$COMMAND" in
    up) up ;;
    down) down ;;
    *) usage; exit 1 ;;
esac
