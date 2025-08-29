#!/usr/bin/env bash
set -euo pipefail

# Required inputs (passed via environment from Make)
: "${ISTIO_VERSION:?ISTIO_VERSION is required}"
: "${ISTIO_PROFILE:?ISTIO_PROFILE is required}"

# Optional (have sensible defaults)
ISTIO_HUB="${ISTIO_HUB:-}"
KIND_CONTEXT="${KIND_CONTEXT:-kind-kind}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
ISTIOCTL_DIR="${ISTIOCTL_DIR:-/tmp}"
KUBECONFIG_DOCKER="${KUBECONFIG_DOCKER:-$ISTIOCTL_DIR/kubeconfig-docker}"
ISTIOCTL_BIN="${ISTIOCTL_BIN:-istioctl}"

resolve_hub() {
  local v="$ISTIO_VERSION"
  local hub="${ISTIO_HUB}"
  if [[ -z "$hub" ]]; then
    if [[ "$v" =~ -alpha|-[0-9a-f]{7,}$ ]]; then
      hub="gcr.io/istio-testing"
    elif [[ "$v" =~ -rc\.[0-9]+$ ]]; then
      hub="gcr.io/istio-release"
    else
      hub="gcr.io/istio-release"
    fi
  fi

  # Guardrail: if the tag isn't in that hub, try the other one
  if ! docker manifest inspect "${hub}/pilot:${ISTIO_VERSION}" >/dev/null 2>&1; then
    local alt="gcr.io/istio-release"
    [[ "$hub" == "gcr.io/istio-release" ]] && alt="gcr.io/istio-testing"
    if docker manifest inspect "${alt}/pilot:${ISTIO_VERSION}" >/dev/null 2>&1; then
      echo "Auto-switching hub to ${alt} (found pilot:${ISTIO_VERSION})"
      hub="$alt"
    else
      echo "ERROR: pilot:${ISTIO_VERSION} not found in ${hub} or ${alt}. Set ISTIO_HUB explicitly." >&2
      exit 1
    fi
  fi

  echo "$hub"
}

prepare_kubeconfig_docker() {
  [[ -f "$KUBECONFIG" ]] || { echo "ERROR: kubeconfig '$KUBECONFIG' not found" >&2; exit 1; }
  mkdir -p "$ISTIOCTL_DIR"
  cp "$KUBECONFIG" "$KUBECONFIG_DOCKER"
  # map localhost API server to host.docker.internal for macOS Docker
  sed -E -i.bak 's#https://(127\.0\.0\.1|localhost):([0-9]+)#https://host.docker.internal:\2#g' "$KUBECONFIG_DOCKER"
  rm -f "$KUBECONFIG_DOCKER.bak"
  kubectl config set-cluster "$KIND_CONTEXT" --kubeconfig "$KUBECONFIG_DOCKER" --insecure-skip-tls-verify=true >/dev/null
}

main() {
  local os hub
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  hub="$(resolve_hub)"
  echo "Resolved hub: $hub"

  if [[ "$os" == "darwin" ]]; then
    prepare_kubeconfig_docker
    echo "Running containerized istioctl against kind via host.docker.internal ..."
    docker run --rm \
      -v "$KUBECONFIG_DOCKER:/kubeconfig:ro" \
      -e KUBECONFIG=/kubeconfig \
      "gcr.io/istio-testing/istioctl:${ISTIO_VERSION}" \
      install -y \
        --set "profile=${ISTIO_PROFILE}" \
        --set "values.global.hub=${hub}" \
        --set "values.global.tag=${ISTIO_VERSION}" \
        --set values.pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true \
        --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
  else
    # Linux (or other) — use local istioctl if present, else error
    if ! command -v "$ISTIOCTL_BIN" >/dev/null 2>&1; then
      echo "ERROR: istioctl not found at ISTIOCTL_BIN='$ISTIOCTL_BIN' and not in PATH." >&2
      echo "       Either build/download istioctl or run via the Docker method you use on macOS." >&2
      exit 1
    fi
    "$ISTIOCTL_BIN" install -y \
      --set "profile=${ISTIO_PROFILE}" \
      --set "values.global.hub=${hub}" \
      --set "values.global.tag=${ISTIO_VERSION}" \
      --set values.pilot.env.SUPPORT_GATEWAY_API_INFERENCE_EXTENSION=true \
      --set values.pilot.env.ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true
  fi
}

main "$@"
