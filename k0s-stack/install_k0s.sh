#!/usr/bin/env bash

# Exit immediately on error
# -e : stop on command error
# -u : fail on undefined variable
# -o pipefail : fail if any command in pipeline fails
set -euo pipefail

# -----------------------------------------------------------------------------
# Global configuration
# -----------------------------------------------------------------------------

# Kubernetes node name
K0S_NODE_NAME="${K0S_NODE_NAME:-k0s1}"

# kubeconfig location for vagrant user
KUBECONFIG_DIR="/home/vagrant/.k0s"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/kubeconfig"

# Bash configuration file
BASHRC="/home/vagrant/.bashrc"

# -----------------------------------------------------------------------------
# Tool versions
# -----------------------------------------------------------------------------

# "stable" automatically resolves latest stable kubectl release
KUBECTL_VERSION="${KUBECTL_VERSION:-stable}"

# Fixed versions for reproducible lab environments
KUBE_PS1_VERSION="${KUBE_PS1_VERSION:-v0.9.0}"
KUBECTX_VERSION="${KUBECTX_VERSION:-v0.9.5}"
K9S_VERSION="${K9S_VERSION:-v0.32.5}"

# -----------------------------------------------------------------------------
# Resolve latest GitHub release tag
# -----------------------------------------------------------------------------

github_latest_tag() {
  local repo="$1"

  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep '"tag_name":' \
    | cut -d '"' -f 4
}

# -----------------------------------------------------------------------------
# Resolve versions if "latest" is requested
# -----------------------------------------------------------------------------

resolve_versions() {

  if [ "${KUBE_PS1_VERSION}" = "latest" ]; then
    KUBE_PS1_VERSION="$(github_latest_tag jonmosco/kube-ps1)"
  fi

  if [ "${KUBECTX_VERSION}" = "latest" ]; then
    KUBECTX_VERSION="$(github_latest_tag ahmetb/kubectx)"
  fi

  if [ "${K9S_VERSION}" = "latest" ]; then
    K9S_VERSION="$(github_latest_tag derailed/k9s)"
  fi

  if [ "${KUBECTL_VERSION}" = "stable" ]; then
    KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  fi
}

# -----------------------------------------------------------------------------
# Install and start k0s controller
# -----------------------------------------------------------------------------

install_k0s() {

  # Install k0s binary if missing
  if ! command -v k0s >/dev/null 2>&1; then
    curl -fL https://get.k0s.sh -o /tmp/get-k0s.sh
    sudo sh /tmp/get-k0s.sh
    rm /tmp/get-k0s.sh
  fi

  # Install controller service if not already installed
  if [ ! -f /etc/systemd/system/k0scontroller.service ]; then
    sudo k0s install controller --single
  fi

  # Start k0s service
  sudo k0s start
}

# -----------------------------------------------------------------------------
# Wait for Kubernetes API server availability
# -----------------------------------------------------------------------------

wait_api() {

  until [ "$(curl -k -s -o /dev/null -w '%{http_code}' https://127.0.0.1:6443)" = "401" ]; do
    printf '.'
    sleep 1
  done

  echo
}

# -----------------------------------------------------------------------------
# Install kubectl and configure kubeconfig
# -----------------------------------------------------------------------------

install_kubectl() {

  # Install kubectl if missing
  if ! command -v kubectl >/dev/null 2>&1; then

    curl -fsSLO \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

    sudo install \
      -o root \
      -g root \
      -m 0755 \
      kubectl \
      /usr/local/bin/kubectl

    rm -f kubectl
  fi

  # Create kubeconfig directory
  sudo mkdir -p "${KUBECONFIG_DIR}"
  sudo chown vagrant:vagrant "${KUBECONFIG_DIR}"

  # Copy admin kubeconfig for vagrant user
  sudo install \
    -o vagrant \
    -g vagrant \
    -m 600 \
    /var/lib/k0s/pki/admin.conf \
    "${KUBECONFIG_FILE}"

  # Export KUBECONFIG automatically on shell startup
  if ! grep -q "KUBECONFIG=${KUBECONFIG_FILE}" "${BASHRC}"; then
    echo "export KUBECONFIG=${KUBECONFIG_FILE}" \
      | sudo tee -a "${BASHRC}" >/dev/null
  fi
}

# -----------------------------------------------------------------------------
# Wait for Kubernetes node readiness
# -----------------------------------------------------------------------------

wait_ready() {

  echo "[INFO] Waiting for node registration..."

  until KUBECONFIG="${KUBECONFIG_FILE}" \
    kubectl get node "${K0S_NODE_NAME}" >/dev/null 2>&1; do

    printf '.'
    sleep 2
  done

  echo
  echo "[INFO] Waiting for node readiness..."

  KUBECONFIG="${KUBECONFIG_FILE}" kubectl wait \
    --for=condition=Ready \
    "node/${K0S_NODE_NAME}" \
    --timeout=300s
}

# -----------------------------------------------------------------------------
# Install kube-ps1 prompt helper
# -----------------------------------------------------------------------------

install_kube_ps1() {

  if [ ! -f /usr/local/bin/kube-ps1.sh ]; then

    wget -q \
      "https://github.com/jonmosco/kube-ps1/archive/refs/tags/${KUBE_PS1_VERSION}.tar.gz"

    tar xzf "${KUBE_PS1_VERSION}.tar.gz"

    sudo install \
      -o root \
      -g root \
      -m 0755 \
      "kube-ps1-${KUBE_PS1_VERSION#v}/kube-ps1.sh" \
      /usr/local/bin/kube-ps1.sh
  fi
}

# -----------------------------------------------------------------------------
# Install kubectx and kubens
# -----------------------------------------------------------------------------

install_kubectx_kubens() {

  # Install kubectx
  if ! command -v kubectx >/dev/null 2>&1; then

    sudo curl -fsSL \
      "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubectx" \
      -o /usr/local/bin/kubectx

    sudo chmod +x /usr/local/bin/kubectx
  fi

  # Install kubens
  if ! command -v kubens >/dev/null 2>&1; then

    sudo curl -fsSL \
      "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubens" \
      -o /usr/local/bin/kubens

    sudo chmod +x /usr/local/bin/kubens
  fi
}

# -----------------------------------------------------------------------------
# Install k9s terminal UI
# -----------------------------------------------------------------------------

install_k9s() {

  if ! command -v k9s >/dev/null 2>&1; then

    wget -q \
      "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_linux_amd64.deb"

    sudo apt install -y ./k9s_linux_amd64.deb

    rm -f k9s_linux_amd64.deb
  fi
}

# -----------------------------------------------------------------------------
# Configure shell environment
# -----------------------------------------------------------------------------

configure_bashrc() {

  # Enable kubectl bash completion
  if ! grep -q "kubectl completion bash" "${BASHRC}"; then

    echo 'source <(kubectl completion bash)' \
      | sudo tee -a "${BASHRC}" >/dev/null
  fi

  # Configure kube-ps1 prompt
  if ! grep -q "kube-ps1.sh" "${BASHRC}"; then

    cat << 'EOF' | sudo tee -a "${BASHRC}" >/dev/null

# kube-ps1
source /usr/local/bin/kube-ps1.sh

KUBE_PS1_SYMBOL_ENABLE=true

PS1='[K8SLAB \u@\h \W] $(kube_ps1)\$ '

EOF
  fi

  # Kubernetes aliases
  if ! grep -q "alias k='kubectl'" "${BASHRC}"; then

    cat << 'EOF' | sudo tee -a "${BASHRC}" >/dev/null

# Kubernetes aliases
alias k='kubectl'
alias kx='kubectx'
alias kn='kubens'

alias kg='kubectl get'
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kga='kubectl get all --all-namespaces'

alias kcc='kubectl config current-context'
alias kuc='kubectl config use-context'

# Kubeconfig
export KUBECONFIG=/home/vagrant/.k0s/kubeconfig
EOF
  fi

  # Ensure correct ownership
  sudo chown vagrant:vagrant "${BASHRC}"
}

# -----------------------------------------------------------------------------
# Kubernetes status
# -----------------------------------------------------------------------------

kube_status() {

  # Display Kubernetes node status
KUBECONFIG="${KUBECONFIG_FILE}" kubectl get nodes
}

# -----------------------------------------------------------------------------
# Install Kubernetes tooling
# -----------------------------------------------------------------------------

install_tooling() {

  sudo apt-get update -qq

  sudo apt-get install -y -qq bash-completion wget curl tar ca-certificates >/dev/null

  # Temporary working directory
  tmpdir="$(mktemp -d)"

  cd "${tmpdir}"

  install_kube_ps1
  install_kubectx_kubens
  install_k9s

  configure_bashrc

  # Cleanup temporary files
  rm -rf "${tmpdir}"
}

# -----------------------------------------------------------------------------
# Main execution flow
# -----------------------------------------------------------------------------

resolve_versions
install_k0s
wait_api
install_kubectl
wait_ready
kube_status
install_tooling