#!/usr/bin/env bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# One-time setup for running the Traffic Intersection Agent as an OpenShell sandbox:
# agent-sandbox controller, OpenShell CLI, gateway chart, and the CLI's mTLS registration.
# Run 'openshell-helm.sh up' afterwards to create the sandbox itself.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==> $*${NC}"; }
warn() { echo -e "${YELLOW}WARNING: $*${NC}" >&2; }
err()  { echo -e "${RED}ERROR: $*${NC}" >&2; }

OPENSHELL_VERSION="0.0.116"
SANDBOX_CRD_VERSION="v1.0.2"
GATEWAY_NAMESPACE="openshell"
GATEWAY="kubernetes"
GATEWAY_PORT="8080"
WORKSPACE="openshell"
RUNTIME_CLASS="kata-qemu"
NAMESPACE=""
CLIENT_SECRET="openshell-client-tls"

PROXY_URL="${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
PROXY_URL="${PROXY_URL%/}"
PROXY_NO_PROXY="${no_proxy:-${NO_PROXY:-}}"

if [ -n "$PROXY_URL" ] && [[ "$PROXY_URL" != http://* ]]; then
    err "The proxy must start with http:// (HTTPS-to-proxy is not supported). Got: ${PROXY_URL}"
    exit 1
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> --namespace <release-namespace>

Commands:
  install     Install the agent-sandbox controller, OpenShell CLI, and gateway, then
              register the gateway with the CLI. Safe to re-run.
  certs       Restart the gateway port-forward and refresh the local mTLS bundle.
              Run this after the gateway pod restarts or the chart is upgraded.
  uninstall   Remove the gateway and the copied client secret.

Options:
  --namespace <ns>   Namespace the STIA release is (or will be) deployed in; it is
                     created if missing. Required for install and uninstall.
  -h, --help         Show this help

Cluster egress uses https_proxy/http_proxy and no_proxy from the environment.
Edit the configuration block at the top of this script to change any other default.
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "$1 is required but not found in PATH."
        exit 1
    fi
}

install_cli() {
    local want="$OPENSHELL_VERSION" have=""
    if command -v openshell >/dev/null 2>&1; then
        have=$(openshell --version 2>/dev/null | awk '{print $NF}')
    fi
    if [ "$have" = "$want" ]; then
        log "OpenShell CLI ${have} already installed."
        return
    fi
    log "Installing OpenShell CLI v${want}..."
    if ! curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh \
        | OPENSHELL_VERSION="v${want}" sh; then
        warn "Downloading the installer failed; falling back to a git clone of the v${want} tag."
        install_cli_from_clone
    fi
    command -v openshell >/dev/null 2>&1 || { err "OpenShell CLI installation failed."; exit 1; }
}

install_cli_from_clone() {
    require_cmd git
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/openshell-src.XXXXXX")
    if ! git clone --depth 1 --branch "v${OPENSHELL_VERSION}" \
        https://github.com/NVIDIA/OpenShell.git "$dir" >/dev/null 2>&1; then
        rm -rf "$dir"
        err "Could not clone https://github.com/NVIDIA/OpenShell.git at tag v${OPENSHELL_VERSION}."
        exit 1
    fi
    if ! OPENSHELL_VERSION="v${OPENSHELL_VERSION}" sh "${dir}/install.sh"; then
        rm -rf "$dir"
        err "The OpenShell installer failed."
        exit 1
    fi
    rm -rf "$dir"
}

install_sandbox_controller() {
    log "Installing the agent-sandbox controller (${SANDBOX_CRD_VERSION})..."
    kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${SANDBOX_CRD_VERSION}/sandbox.yaml"
    if ! kubectl rollout status deployment -n agent-sandbox-system --timeout=180s >/dev/null 2>&1; then
        warn "The agent-sandbox controller is not ready yet; sandbox creation will fail until it is."
        kubectl get pods -n agent-sandbox-system
    fi
}

install_gateway() {
    log "Installing the OpenShell gateway ${OPENSHELL_VERSION} into namespace '${GATEWAY_NAMESPACE}'..."
    local args=(
        upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart
        --version "$OPENSHELL_VERSION"
        -n "$GATEWAY_NAMESPACE" --create-namespace
        --set "server.defaultRuntimeClassName=${RUNTIME_CLASS}"
        --set "server.sandboxNamespace=${NAMESPACE}"
        --set server.auth.allowUnauthenticatedUsers=true
        --wait --timeout 10m
    )
    if [ -n "$PROXY_URL" ]; then
        log "Routing cluster egress through ${PROXY_URL}"
        args+=(--set "upstreamProxy.url=${PROXY_URL}")

        if [ -n "$PROXY_NO_PROXY" ]; then
            # helm reads unescaped commas as list separators
            local no_proxy_list="${PROXY_NO_PROXY//,/\\,}"
            args+=(--set-string "upstreamProxy.noProxy=${no_proxy_list}")
        fi
    fi
    helm "${args[@]}"
}

copy_client_secret() {
    log "Copying the client mTLS secret into namespace '${NAMESPACE}'..."
    local i
    for i in $(seq 1 60); do
        if kubectl get secret "$CLIENT_SECRET" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
            break
        fi
        if [ "$i" -eq 60 ]; then
            err "Secret '${CLIENT_SECRET}' was not created in namespace '${GATEWAY_NAMESPACE}'."
            exit 1
        fi
        sleep 2
    done
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    # kubectl refuses the apply unless the source namespace and identity fields are stripped
    kubectl get secret "$CLIENT_SECRET" -n "$GATEWAY_NAMESPACE" -o yaml \
        | grep -v '^\s*\(namespace\|resourceVersion\|uid\|creationTimestamp\|selfLink\):' \
        | kubectl apply -n "$NAMESPACE" -f - >/dev/null
}

start_port_forward() {
    pkill -f "port-forward -n ${GATEWAY_NAMESPACE} svc/openshell" >/dev/null 2>&1 || true
    sleep 1
    log "Port-forwarding the gateway to 127.0.0.1:${GATEWAY_PORT}..."
    nohup kubectl port-forward -n "$GATEWAY_NAMESPACE" svc/openshell \
        "${GATEWAY_PORT}:8080" >/dev/null 2>&1 &
    local i
    for i in $(seq 1 30); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${GATEWAY_PORT}") 2>/dev/null; then
            exec 3>&-
            return
        fi
        sleep 1
    done
    err "The gateway port-forward did not start on 127.0.0.1:${GATEWAY_PORT}."
    exit 1
}

install_mtls_bundle() {
    # 'gateway add --local' regenerates this directory, so the bundle must be copied afterwards
    local dir="$HOME/.config/openshell/gateways/${GATEWAY}/mtls"
    log "Installing the gateway's client certificates into ${dir}..."
    mkdir -p "$dir"
    local f
    for f in ca.crt tls.crt tls.key; do
        kubectl -n "$GATEWAY_NAMESPACE" get secret "$CLIENT_SECRET" \
            -o "jsonpath={.data.${f/./\\.}}" | base64 -d > "${dir}/${f}"
    done
    chmod 600 "${dir}/tls.key"
}

register_gateway() {
    if openshell gateway list 2>/dev/null | grep -q "\b${GATEWAY}\b"; then
        log "Gateway '${GATEWAY}' is already registered."
    else
        log "Registering gateway '${GATEWAY}'..."
        openshell gateway add "https://127.0.0.1:${GATEWAY_PORT}" --local --name "$GATEWAY"
    fi
    install_mtls_bundle
}

restart_forwards() {
    # sandbox forwards tunnel through the gateway port-forward, so they die with it
    local list sandbox port status restarted=0
    list=$(openshell -g "$GATEWAY" --workspace "$WORKSPACE" forward list 2>/dev/null) || return 0
    # the CLI colourises the status column, so strip the escape sequences before matching
    list=$(printf '%s\n' "$list" | sed 's/\x1b\[[0-9;]*m//g' | tail -n +2)
    while read -r sandbox _ port _ status; do
        [ "$status" = "dead" ] || continue
        openshell -g "$GATEWAY" --workspace "$WORKSPACE" forward stop "$port" "$sandbox" >/dev/null 2>&1 || true
        if openshell -g "$GATEWAY" --workspace "$WORKSPACE" forward start "$port" "$sandbox" --background >/dev/null 2>&1; then
            restarted=$((restarted + 1))
        else
            warn "Could not restart the forward for ${sandbox}:${port}."
        fi
    done <<< "$list"
    [ "$restarted" -gt 0 ] && log "Restarted ${restarted} sandbox port forward(s)."
    return 0
}

require_namespace() {
    if [ -z "$NAMESPACE" ]; then
        err "--namespace is required: pass the namespace the STIA release is (or will be) deployed in."
        exit 1
    fi
}

do_install() {
    require_cmd kubectl
    require_cmd helm
    require_cmd curl
    require_namespace
    install_sandbox_controller
    install_cli
    install_gateway
    copy_client_secret
    start_port_forward
    register_gateway
    openshell -g "$GATEWAY" status
    cat <<EOF

Setup complete. Keep the port-forward running (PID $(pgrep -f "port-forward -n ${GATEWAY_NAMESPACE} svc/openshell" | head -n 1)).
Create the sandbox with:

  ./chart/openshell-helm.sh up --namespace ${NAMESPACE}
EOF
}

do_certs() {
    require_cmd kubectl
    start_port_forward
    install_mtls_bundle
    openshell -g "$GATEWAY" status
    restart_forwards
}

do_uninstall() {
    require_cmd kubectl; require_cmd helm
    require_namespace
    pkill -f "port-forward -n ${GATEWAY_NAMESPACE} svc/openshell" >/dev/null 2>&1 || true
    helm uninstall openshell -n "$GATEWAY_NAMESPACE" 2>/dev/null || true
    kubectl delete secret "$CLIENT_SECRET" -n "$NAMESPACE" --ignore-not-found
    log "Gateway removed. The OpenShell CLI and ~/.config/openshell were left in place."
}

COMMAND="${1:-}"
[ $# -gt 0 ] && shift || true
while [ $# -gt 0 ]; do
    case "$1" in
        --namespace)
            [ $# -ge 2 ] || { err "--namespace requires a value."; usage; exit 1; }
            NAMESPACE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

case "$COMMAND" in
    install) do_install ;;
    certs) do_certs ;;
    uninstall) do_uninstall ;;
    -h|--help|"") usage; exit 0 ;;
    *) err "Unknown command: $COMMAND"; usage; exit 1 ;;
esac
