# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# OpenShell integration for the Traffic Intersection Agent (Docker Compose flow). Sourced
# by setup.sh; relies on vars/colors exported there (APP_DIR, PROJECT_NAME, RI_DIR, etc.).

os_err() { echo -e "${RED}ERROR: $*${NC}" >&2; }

os_require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        os_err "$1 is required but not found in PATH."
        return 1
    fi
}

os_delete_sandbox() {
    openshell sandbox delete "$1" >/dev/null 2>&1 || true
}

# extra args (--upload, --env, etc.) pass through as-is
os_create_sandbox() {
    local sandbox="$1" image="$2"
    shift 2
    openshell sandbox create --name "$sandbox" --from "$image" "$@" --no-tty -- true
}

# extra --add-endpoint args pass through as-is
os_apply_policy() {
    local sandbox="$1"
    shift
    openshell policy update "$sandbox" "$@" --binary /usr/local/bin/python --wait
}

# blocking — caller should background/redirect it
os_exec_agent() {
    openshell sandbox exec -n "$1" -- \
        bash -lc 'export PATH=/app/.venv/bin:$PATH; cd /app && exec bash docker-entrypoint.sh'
}

os_forward_ports() {
    local sandbox="$1" backend_port="$2" ui_port="$3"
    openshell forward start --background "$backend_port" "$sandbox" || return 1
    openshell forward start --background "$ui_port" "$sandbox"
}

# sets OPENSHELL_OVERLAY_AGENT/OPENSHELL_SANDBOX_NAME (empty when disabled)
configure_openshell() {
    OPENSHELL_OVERLAY_AGENT=""
    OPENSHELL_SANDBOX_NAME=""

    if [ "$ENABLE_OPENSHELL" = "true" ]; then
        os_require_cmd openshell || { os_err "OpenShell CLI is required when ENABLE_OPENSHELL=true."; return 1; }
        OPENSHELL_OVERLAY_AGENT="-f ${APP_DIR}/docker/openshell-overlay-agent.yaml"
        OPENSHELL_SANDBOX_NAME="stia-$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]_' '[:lower:]-' | cut -c1-14)"
        export OPENSHELL_DOCKER_GATEWAY=$(docker network inspect openshell-docker --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
        if [ -z "$OPENSHELL_DOCKER_GATEWAY" ]; then
            os_err "OpenShell Docker network is unavailable. Start the local OpenShell gateway first."
            return 1
        fi
    fi
    return 0
}

# OpenShell can't inspect TLS-wrapped WebSocket traffic, so the sandbox uses plaintext instead
patch_broker_for_openshell() {
    if [ "$ENABLE_OPENSHELL" != "true" ]; then
        return 0
    fi

    local mosquitto_conf="$RI_DIR/src/mosquitto/mosquitto-secure.conf"
    local ws_port="${OPENSHELL_MQTT_PORT:-1885}"
    if [ -f "$mosquitto_conf" ] && ! grep -q "^listener ${ws_port}$" "$mosquitto_conf"; then
        echo -e "${BLUE}==> Adding plaintext WebSocket listener (port ${ws_port}) for OpenShell sandbox MQTT access...${NC}"
        printf '\nlistener %s\nprotocol websockets\n' "$ws_port" | sudo tee -a "$mosquitto_conf" >/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}ERROR: Failed to add OpenShell WebSocket listener to broker config.${NC}"
            return 1
        fi
    fi
    return 0
}

# reverts patch_broker_for_openshell regardless of ENABLE_OPENSHELL (a prior run may have left it)
revert_broker_openshell_patch() {
    local mosquitto_conf="$RI_DIR/src/mosquitto/mosquitto-secure.conf"
    local ws_port="${OPENSHELL_MQTT_PORT:-1885}"
    if [ -f "$mosquitto_conf" ] && grep -q "^listener ${ws_port}$" "$mosquitto_conf"; then
        echo -e "${YELLOW}==> Removing OpenShell plaintext WebSocket listener (port ${ws_port}) from broker config...${NC}"
        sudo sed -i -e "/^listener ${ws_port}\$/,/^protocol websockets\$/d" -e '${/^$/d}' "$mosquitto_conf"
    fi
}

delete_openshell_sandbox() {
    if [ "$ENABLE_OPENSHELL" = "true" ]; then
        os_delete_sandbox "$OPENSHELL_SANDBOX_NAME"
    fi
}

start_openshell_agent() {
    local certificate_path="$RI_DIR/src/secrets/certs/scenescape-ca.pem"
    local openshell_gateway
    local agent_image="${REGISTRY:-}smart-traffic-intersection-agent:${TAG:-latest}"

    if [ ! -f "$certificate_path" ]; then
        os_err "OpenShell agent certificate not found: ${certificate_path}"
        return 1
    fi

    openshell_gateway=$(docker network inspect openshell-docker --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)
    if [ -z "$openshell_gateway" ]; then
        os_err "OpenShell Docker network is unavailable. Start the local OpenShell gateway first."
        return 1
    fi

    delete_openshell_sandbox
    os_create_sandbox "$OPENSHELL_SANDBOX_NAME" "$agent_image" \
        --upload "$certificate_path:/app/secrets/certs/scenescape-ca.pem" \
        --env "VLM_BASE_URL=http://host.docker.internal:${OPENSHELL_OVMS_PORT:-8000}" \
        --env "METRICS_MANAGER_URL=http://host.docker.internal:${OPENSHELL_METRICS_PORT:-9090}" \
        --env "METRICS_STREAM_URL=http://host.docker.internal:${OPENSHELL_METRICS_PORT:-9090}/metrics/stream" \
        --env "METRICS_HEALTH_URL=http://host.docker.internal:${OPENSHELL_METRICS_PORT:-9090}/health" \
        --env "VLM_MODEL_NAME=${VLM_MODEL_NAME}" \
        --env "VLM_TARGET_DEVICE=${VLM_TARGET_DEVICE:-CPU}" \
        --env "VLM_WEIGHT_FORMAT=${VLM_WEIGHT_FORMAT:-}" \
        --env "VLM_TIMEOUT_SECONDS=${VLM_TIMEOUT_SECONDS:-}" \
        --env "VLM_MAX_COMPLETION_TOKENS=${VLM_MAX_COMPLETION_TOKENS:-}" \
        --env "VLM_TEMPERATURE=${VLM_TEMPERATURE:-}" \
        --env "VLM_TOP_P=${VLM_TOP_P:-}" \
        --env "USE_API=true" \
        --env "REFRESH_INTERVAL=${REFRESH_INTERVAL:-15}" \
        --env "LOG_LEVEL=${LOG_LEVEL:-INFO}" \
        --env "MQTT_HOST=host.docker.internal" \
        --env "MQTT_PORT=${OPENSHELL_MQTT_PORT:-1885}" \
        --env "MQTT_TRANSPORT=websockets" \
        --env "MQTT_USE_TLS=false" \
        --env "MQTT_PROXY_HOST=10.200.0.1" \
        --env "MQTT_PROXY_PORT=3128" \
        --env "INTERSECTION_NAME=${INTERSECTION_NAME}" \
        --env "INTERSECTION_LATITUDE=${INTERSECTION_LATITUDE}" \
        --env "INTERSECTION_LONGITUDE=${INTERSECTION_LONGITUDE}" \
        --env "WEATHER_MOCK=${WEATHER_MOCK:-false}" \
        --env "HIGH_DENSITY_THRESHOLD=${HIGH_DENSITY_THRESHOLD:-10}" \
        || return 1

    os_apply_policy "$OPENSHELL_SANDBOX_NAME" \
        --add-endpoint "host.docker.internal:${OPENSHELL_MQTT_PORT:-1885}:read-write:websocket:enforce:allowed-ip=${openshell_gateway}" \
        --add-endpoint "host.docker.internal:${OPENSHELL_OVMS_PORT:-8000}:read-write:rest:enforce:allowed-ip=${openshell_gateway}" \
        --add-endpoint "host.docker.internal:${OPENSHELL_METRICS_PORT:-9090}:read-write:rest:enforce:allowed-ip=${openshell_gateway}" \
        || return 1

    nohup os_exec_agent "$OPENSHELL_SANDBOX_NAME" > "${APP_DIR}/.openshell-traffic-agent.log" 2>&1 &
    os_forward_ports "$OPENSHELL_SANDBOX_NAME" "${AGENT_BACKEND_PORT:-8081}" "${AGENT_UI_PORT:-7860}"
}

# not visible to docker-ps (not a Compose-managed container)
print_openshell_endpoints() {
    if [ "$ENABLE_OPENSHELL" = "true" ]; then
        echo -e "${CYAN}Access Traffic Intersection Agent API Docs -> http://$HOST_IP:8081/docs${NC}"
        echo -e "${CYAN}Access Traffic Intersection Agent UI -> http://$HOST_IP:7860${NC}"
    fi
}
