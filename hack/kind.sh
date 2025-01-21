#!/usr/bin/env bash

set -e

# The name of the kind cluster
CLUSTER_NAME="${CLUSTER_NAME:-"kind"}"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to display usage information
usage() {
  echo "Usage: $0 [create|delete]"
  exit 1
}

# Check if kubectl is installed
if ! command_exists kubectl; then
  echo "kubectl is not installed. Please install kubectl before running this script."
  exit 1
fi

# Check if kind is installed
if ! command_exists kind; then
  echo "kind is not installed. Please install kind before running this script."
  exit 1
fi

# Check if helm is installed
if ! command_exists helm; then
  echo "helm is not installed. Please install helm before running this script."
  exit 1
fi

# Check the argument
if [ $# -ne 1 ]; then
  usage
fi

ACTION=$1

# Validate input argument
if [ "$ACTION" != "create" ] && [ "$ACTION" != "delete" ]; then
  echo "Invalid argument. Please use 'create' or 'delete'."
  usage
fi

# Check if the cluster already exists
CLUSTER_EXISTS=$(kind get clusters)

# Handle the case where no clusters are found
if [[ "$CLUSTER_EXISTS" == "No kind clusters found." ]]; then
  CLUSTER_EXISTS=""
fi

if [ "$ACTION" == "create" ]; then
  if echo "$CLUSTER_EXISTS" | grep -qw "$CLUSTER_NAME"; then
    echo "Cluster '$CLUSTER_NAME' already exists. Exiting."
    exit 1
  fi

  # Cluster configuration YAML
  cat <<EOF > kind-config.yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
- role: control-plane
  image: kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72
  # required for GPU workaround (https://github.com/NVIDIA/nvidia-docker/issues/614#issuecomment-423991632)
  extraMounts:
    - hostPath: /dev/null
      containerPath: /var/run/nvidia-container-devices/all
EOF

  # Create the kind cluster
  echo "Creating kind cluster..."
  kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml

  # Cleanup
  rm kind-config.yaml

  echo "Kind cluster created successfully."

  echo "Implementing nvidia-docker/issues/614 workaround..."
  docker exec -ti $CLUSTER_NAME-control-plane ln -s /sbin/ldconfig /sbin/ldconfig.real

  echo "Installing Nvidia GPU operator..."
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
  helm repo update
  helm install --wait --generate-name \
       -n gpu-operator --create-namespace \
       nvidia/gpu-operator --set driver.enabled=false

  echo "Installation completed successfully."

elif [ "$ACTION" == "delete" ]; then
  if [ -z "$CLUSTER_EXISTS" ]; then
    echo "Cluster '$CLUSTER_NAME' does not exist. Exiting."
    exit 1
  fi

  # Delete the kind cluster
  echo "Deleting kind cluster..."
  kind delete cluster --name "$CLUSTER_NAME"

  echo "Kind cluster deleted successfully."
fi
