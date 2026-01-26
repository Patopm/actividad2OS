#!/bin/bash
#
# Setup script for Red Hat Enterprise Linux
# Installs all dependencies needed for the OS parallel project
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root or with sudo
check_privileges() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root or with sudo"
    exit 1
  fi
}

# Enable necessary repositories
enable_repos() {
  log_info "Enabling CodeReady Builder repository..."
  subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms 2>/dev/null ||
    dnf config-manager --set-enabled crb 2>/dev/null ||
    log_warn "Could not enable CRB repo, some packages might not install"
}

# Install development tools
install_dev_tools() {
  log_info "Installing development tools..."
  dnf groupinstall -y "Development Tools"
  dnf install -y \
    gcc \
    gcc-c++ \
    make \
    cmake \
    git \
    curl \
    wget \
    vim \
    perf \
    strace
}

# Install Rust
install_rust() {
  log_info "Installing Rust..."
  if command -v rustc &>/dev/null; then
    log_info "Rust is already installed: $(rustc --version)"
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
  fi

  # Ensure cargo is in PATH for current session
  export PATH="$HOME/.cargo/bin:$PATH"

  log_info "Rust version: $(rustc --version)"
  log_info "Cargo version: $(cargo --version)"
}

# Install OpenMPI
install_openmpi() {
  log_info "Installing OpenMPI..."
  dnf install -y \
    openmpi \
    openmpi-devel

  # Add OpenMPI to PATH
  echo 'export PATH=/usr/lib64/openmpi/bin:$PATH' >>~/.bashrc
  echo 'export LD_LIBRARY_PATH=/usr/lib64/openmpi/lib:$LD_LIBRARY_PATH' >>~/.bashrc

  # Load for current session
  export PATH="/usr/lib64/openmpi/bin:${PATH:-}"
  export LD_LIBRARY_PATH="/usr/lib64/openmpi/lib:${LD_LIBRARY_PATH:-}"
  # Verify installation
  if command -v mpirun &>/dev/null; then
    log_info "OpenMPI installed successfully: $(mpirun --version | head -1)"
  else
    log_error "OpenMPI installation failed"
    exit 1
  fi
}

# Install Node.js and pnpm
install_node_pnpm() {
  log_info "Installing Node.js and pnpm..."

  # Install Node.js via dnf
  dnf install -y nodejs

  # Install pnpm
  npm install -g pnpm

  log_info "Node.js version: $(node --version)"
  log_info "pnpm version: $(pnpm --version)"
}

# Install Docker (for cluster simulation)
install_docker() {
  log_info "Installing Docker..."

  # Remove old versions
  dnf remove -y docker docker-client docker-client-latest \
    docker-common docker-latest docker-latest-logrotate \
    docker-logrotate docker-engine podman runc 2>/dev/null || true

  # Add Docker repo
  dnf config-manager --add-repo \
    https://download.docker.com/linux/rhel/docker-ce.repo

  # Install Docker
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Start and enable Docker
  systemctl start docker
  systemctl enable docker

  # Add current user to docker group
  usermod -aG docker "$SUDO_USER" 2>/dev/null ||
    usermod -aG docker "$USER" 2>/dev/null || true

  log_info "Docker installed successfully: $(docker --version)"
}

# Install additional tools for I/O analysis
install_io_tools() {
  log_info "Installing I/O analysis tools..."
  dnf install -y \
    sysstat \
    iotop \
    lsof \
    pciutils \
    usbutils
}

# Configure system for real-time scheduling
configure_realtime() {
  log_info "Configuring system for real-time scheduling..."

  # Add limits for real-time scheduling
  cat >>/etc/security/limits.conf <<'EOF'

# Real-time scheduling limits for OS project
*               soft    rtprio          99
*               hard    rtprio          99
*               soft    memlock         unlimited
*               hard    memlock         unlimited
EOF

  log_info "Real-time scheduling limits configured"
  log_warn "You may need to log out and log back in for limits to take effect"
}

# Print summary
print_summary() {
  echo ""
  echo "=============================================="
  echo "           INSTALLATION SUMMARY"
  echo "=============================================="
  echo ""
  log_info "All dependencies installed successfully!"
  echo ""
  echo "Installed components:"
  echo "  - Development Tools (gcc, make, cmake, etc.)"
  echo "  - Rust and Cargo"
  echo "  - OpenMPI"
  echo "  - Node.js and pnpm"
  echo "  - Docker and Docker Compose"
  echo "  - I/O analysis tools"
  echo ""
  echo "Next steps:"
  echo "  1. Log out and log back in (for Docker group and RT limits)"
  echo "  2. Run 'source ~/.bashrc' to load OpenMPI paths"
  echo "  3. Navigate to project and run 'pnpm install'"
  echo "  4. Run 'pnpm run build' to compile all Rust apps"
  echo ""
  echo "=============================================="
}

# Main execution
main() {
  log_info "Starting RHEL setup for OS Parallel Project..."
  echo ""

  check_privileges
  enable_repos
  install_dev_tools
  install_rust
  install_openmpi
  install_node_pnpm
  install_docker
  install_io_tools
  configure_realtime
  print_summary
}

main "$@"
