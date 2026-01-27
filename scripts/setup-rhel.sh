#!/bin/bash
#
# Setup script for Red Hat Enterprise Linux
# Installs all dependencies needed for the OS parallel project
# Optimized for memory usage and cache management
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# DNF optimization flags - prevent keeping cache and use minimal memory
DNF_OPTS="-y --setopt=keepcache=False --setopt=cachedir=/tmp/dnf-cache-$$"

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Clean DNF cache and temporary files
clean_dnf_cache() {
  log_info "Cleaning DNF cache..."
  dnf clean all 2>/dev/null || true
  rm -rf /var/cache/dnf/* 2>/dev/null || true
  rm -rf /tmp/dnf-cache-* 2>/dev/null || true
}

# Clean temporary files and caches
clean_temp_files() {
  log_info "Cleaning temporary files and caches..."
  
  # Clean DNF cache
  clean_dnf_cache
  
  # Clean temporary directories
  rm -rf /tmp/nvm-install-* 2>/dev/null || true
  rm -rf /tmp/rustup-* 2>/dev/null || true
  
  # Clean npm/pnpm caches if they exist
  if command -v npm &>/dev/null; then
    npm cache clean --force 2>/dev/null || true
  fi
  if command -v pnpm &>/dev/null; then
    pnpm store prune 2>/dev/null || true
  fi
  
  # Clean Rust build artifacts cache (keep only what's needed)
  if [ -d "$HOME/.cargo/registry/cache" ]; then
    find "$HOME/.cargo/registry/cache" -type f -name "*.crate" -mtime +7 -delete 2>/dev/null || true
  fi
  
  # Clean system temporary files
  find /tmp -type f -mtime +1 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +1 -delete 2>/dev/null || true
  
  # Sync to ensure disk writes are complete
  sync
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
  
  # Clean cache after repo operations
  clean_dnf_cache
}

# Install development tools
install_dev_tools() {
  log_info "Installing development tools..."
  dnf groupinstall $DNF_OPTS "Development Tools"
  dnf install $DNF_OPTS \
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
  
  # Clean cache immediately after installation
  clean_dnf_cache
}

# Install Rust
install_rust() {
  log_info "Installing Rust..."
  if command -v rustc &>/dev/null; then
    log_info "Rust is already installed: $(rustc --version)"
  else
    # Use temporary file for rustup installer to clean up after
    local rustup_script="/tmp/rustup-install-$$.sh"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$rustup_script"
    sh "$rustup_script" -y --default-toolchain stable --profile minimal
    rm -f "$rustup_script"
    source "$HOME/.cargo/env"
  fi

  # Ensure cargo is in PATH for current session
  export PATH="$HOME/.cargo/bin:$PATH"

  log_info "Rust version: $(rustc --version)"
  log_info "Cargo version: $(cargo --version)"
  
  # Clean Rust cache of old/unused components
  if command -v rustup &>/dev/null; then
    rustup component remove --toolchain stable rust-docs 2>/dev/null || true
  fi
}

# Install OpenMPI
install_openmpi() {
  log_info "Installing OpenMPI..."
  dnf install $DNF_OPTS \
    openmpi \
    openmpi-devel

  # Add OpenMPI to PATH
  echo 'export PATH=/usr/lib64/openmpi/bin:$PATH' >>~/.bashrc
  echo 'export LD_LIBRARY_PATH=/usr/lib64/openmpi/lib:$LD_LIBRARY_PATH' >>~/.bashrc

  # Load for current session
  export PATH="/usr/lib64/openmpi/bin:${PATH:-}"
  export LD_LIBRARY_PATH="/usr/lib64/openmpi/lib:${LD_LIBRARY_PATH:-}"
  
  # Clean cache after installation
  clean_dnf_cache
  
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

  # Download nvm installer to temporary file for cleanup
  local nvm_script="/tmp/nvm-install-$$.sh"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh > "$nvm_script"
  bash "$nvm_script"
  rm -f "$nvm_script"

  # in lieu of restarting the shell
  \. "$HOME/.nvm/nvm.sh"

  # Download and install Node.js (clean npm cache after)
  nvm install 24
  npm cache clean --force 2>/dev/null || true

  # Install pnpm globally
  npm install -g pnpm
  pnpm store prune 2>/dev/null || true

  log_info "Node.js version: $(node --version)"
  log_info "pnpm version: $(pnpm --version)"
}

# Install Docker (for cluster simulation)
install_docker() {
  log_info "Installing Docker..."

  # Remove old versions and clean cache
  dnf remove $DNF_OPTS docker docker-client docker-client-latest \
    docker-common docker-latest docker-latest-logrotate \
    docker-logrotate docker-engine podman runc 2>/dev/null || true
  clean_dnf_cache

  # Add Docker repo
  dnf config-manager --add-repo \
    https://download.docker.com/linux/rhel/docker-ce.repo

  # Install Docker
  dnf install $DNF_OPTS docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Clean cache after installation
  clean_dnf_cache

  # Start and enable Docker
  systemctl start docker
  systemctl enable docker

  # Add current user to docker group
  usermod -aG docker "$SUDO_USER" 2>/dev/null ||
    usermod -aG docker "$USER" 2>/dev/null || true

  # Clean Docker build cache if it exists
  docker system prune -f 2>/dev/null || true

  log_info "Docker installed successfully: $(docker --version)"
}

# Install additional tools for I/O analysis
install_io_tools() {
  log_info "Installing I/O analysis tools..."
  dnf install $DNF_OPTS \
    sysstat \
    iotop \
    lsof \
    pciutils \
    usbutils
  
  # Clean cache after installation
  clean_dnf_cache
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
  echo "Optimizations applied:"
  echo "  - DNF cache cleaned after each installation step"
  echo "  - Temporary files and caches removed"
  echo "  - Package cache disabled to save disk space"
  echo "  - Old build artifacts cleaned"
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

  # Set up trap to clean up on exit
  trap 'clean_temp_files; exit' INT TERM EXIT

  check_privileges
  enable_repos
  install_dev_tools
  install_rust
  install_openmpi
  install_node_pnpm
  install_docker
  install_io_tools
  configure_realtime
  
  # Final cleanup of all caches and temporary files
  log_info "Performing final cleanup..."
  clean_temp_files
  
  # Clear trap before summary
  trap - INT TERM EXIT
  
  print_summary
}

main "$@"
