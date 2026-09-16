#!/bin/bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Runs the Traffic Intersection Agent as an OpenShell sandbox pod alongside a Helm release
# deployed with `openshell.enabled=true'
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}==> $*${NC}"; }
err() { echo -e "${RED}ERROR: $*${NC}" >&2; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "$1 is required but not found in PATH."
        exit 1
    fi
}

RELEASE="stia"
BACKEND_PORT="8081"
UI_PORT="7860"
GATEWAY="kubernetes"
WORKSPACE="${OPENSHELL_WORKSPACE:-openshell}"
MQTT_HOST="${MQTT_HOST:-}"
MQTT_WS_PORT="${MQTT_WS_PORT:-1885}"
NAMESPACE="${NAMESPACE:-default}"
CREATE_LOG="${TMPDIR:-/tmp}/openshell-sandbox-create.log"

usage() {
    cat <<EOF
Usage: $0 <up|down> [options]

Options:
  --namespace NS        Kubernetes namespace the release is installed in (default: default)
EOF
}

sandbox_name() {
    printf '%s-traffic-agent' "$RELEASE" | tr '[:upper:]_' '[:lower:]-'
}

osh() {
    openshell -g "$GATEWAY" --workspace "$WORKSPACE" "$@"
}

service_port() {
    local service="$1" port_name="$2"
    kubectl get svc "$service" -n "$NAMESPACE" \
        -o jsonpath="{.spec.ports[?(@.name==\"${port_name}\")].port}"
}

# matches the OVMS-registered model id
ovms_value() {
    helm get values -a "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('ovms',{}).get('env',{}).get(sys.argv[1],''))" "$1"
}

# dot-separated path into the release's effective values
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

    if ! openshell -g "$GATEWAY" status >/dev/null 2>&1; then
        err "OpenShell gateway '${GATEWAY}' is not reachable. Install/register a Kubernetes-driver gateway first."
        exit 1
    fi

    if ! openshell -g "$GATEWAY" workspace get "$WORKSPACE" >/dev/null 2>&1; then
        openshell -g "$GATEWAY" workspace create --name "$WORKSPACE" >/dev/null 2>&1 || true
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

    if [ -z "$MQTT_HOST" ]; then
        MQTT_HOST=$(chart_value mqtt.host)
        if [ -z "$MQTT_HOST" ]; then
            local mqtt_service mqtt_ns
            mqtt_service=$(chart_value mqtt.serviceName)
            mqtt_ns=$(chart_value mqtt.brokerNamespace)
            if [ -z "$mqtt_ns" ]; then
                mqtt_ns="$NAMESPACE"
            fi
            if [ -z "$mqtt_service" ]; then
                err "Could not derive the broker host from release '${RELEASE}' values (mqtt.host/mqtt.serviceName). Set MQTT_HOST explicitly."
                exit 1
            fi
            MQTT_HOST="${mqtt_service}.${mqtt_ns}.svc.cluster.local"
        fi
    fi

    local sandbox agent_image
    sandbox=$(sandbox_name)
    agent_image="${REGISTRY:-}smart-traffic-intersection-agent:${TAG:-local}"

    # ':latest' forces imagePullPolicy=Always, so a locally built image is ignored
    if [ "${agent_image##*:}" = "latest" ]; then
        err "Tag 'latest' makes Kubernetes always pull from a registry. Re-tag the local image and set TAG (e.g. TAG=local)."
        exit 1
    fi

    #delete older sanbox pod
    osh sandbox delete "$sandbox" >/dev/null 2>&1 || true

    log "Creating OpenShell sandbox '$sandbox' (gateway '$GATEWAY', workspace '$WORKSPACE') for release '$RELEASE' in namespace '$NAMESPACE'..."
    # create runs the entrypoint and blocks for the agent's lifetime, so detach it
    nohup openshell -g "$GATEWAY" --workspace "$WORKSPACE" sandbox create --name "$sandbox" --from "$agent_image" \
        --forward "$BACKEND_PORT" \
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
        --no-tty -- bash -c 'cd /app && exec bash docker-entrypoint.sh' < /dev/null > "$CREATE_LOG" 2>&1 &

    # the supervisor starts in the workspace dir, so wait on the phase rather than mere existence
    local i phase
    for i in $(seq 1 60); do
        phase=$(osh sandbox get "$sandbox" -o json 2>/dev/null \
            | python3 -c "import json,sys; print(json.load(sys.stdin).get('phase',''))" 2>/dev/null || true)
        case "$phase" in
            Running|Ready) break ;;
            Error|Failed)
                err "Sandbox '$sandbox' entered phase '$phase'. Output from 'sandbox create':"
                cat "$CREATE_LOG" >&2 || true
                exit 1
                ;;
        esac
        if [ "$i" -eq 60 ]; then
            err "Sandbox '$sandbox' did not come up (last phase: '${phase:-unknown}'). Output from 'sandbox create':"
            cat "$CREATE_LOG" >&2 || true
            exit 1
        fi
        sleep 2
    done

    # 'sandbox create' accepts only one --forward, so the UI port is forwarded separately
    osh forward stop "$UI_PORT" "$sandbox" >/dev/null 2>&1 || true
    osh forward start "$UI_PORT" "$sandbox" --background >/dev/null 2>&1

    # egress is deny-by-default until this lands; the agent retries until then
    log "Applying network policy (OVMS/Metrics/MQTT reached via in-cluster Service DNS)..."
    osh policy update "$sandbox" \
        --add-endpoint "${MQTT_HOST}:${MQTT_WS_PORT}:read-write:websocket:enforce" \
        --add-endpoint "${ovms_addr}:${ovms_port}:read-write:rest:enforce" \
        --add-endpoint "${metrics_addr}:${metrics_port}:read-write:rest:enforce" \
        --binary /app/.venv/bin/python --wait

    echo -e "${GREEN}Traffic Intersection Agent running as OpenShell sandbox '$sandbox'.${NC}"
    echo -e "${CYAN}Access API Docs -> http://localhost:${BACKEND_PORT}/docs${NC}"
    echo -e "${CYAN}Access UI        -> http://localhost:${UI_PORT}${NC}"
    echo -e "${CYAN}Stop the agent   -> $0 down --namespace ${NAMESPACE}${NC}"
}

down() {
    require_cmd openshell
    local sandbox
    sandbox=$(sandbox_name)
    osh forward stop "$UI_PORT" "$sandbox" >/dev/null 2>&1 || true
    osh sandbox delete "$sandbox" >/dev/null 2>&1 || true
    echo -e "${YELLOW}Deleted OpenShell sandbox '$sandbox'.${NC}"
}

COMMAND="${1:-}"
if [ "${2:-}" = "--namespace" ]; then
    NAMESPACE="${3:-}"
fi

case "$COMMAND" in
    up|down) "$COMMAND" ;;
    -h|--help) usage ;;
    *) usage; exit 1 ;;
esac
