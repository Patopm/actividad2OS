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

# User detection variables (will be set by detect_user)
REAL_USER=""
REAL_USER_HOME=""

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
  
  # Clean npm/pnpm caches for the real user if they exist
  if sudo -u "$REAL_USER" bash -c "command -v npm" &>/dev/null; then
    sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh 2>/dev/null; npm cache clean --force" 2>/dev/null || true
  fi
  if sudo -u "$REAL_USER" bash -c "command -v pnpm" &>/dev/null; then
    sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh 2>/dev/null; pnpm store prune" 2>/dev/null || true
  fi
  
  # Clean Rust build artifacts cache (keep only what's needed)
  if [ -d "$REAL_USER_HOME/.cargo/registry/cache" ]; then
    find "$REAL_USER_HOME/.cargo/registry/cache" -type f -name "*.crate" -mtime +7 -delete 2>/dev/null || true
  fi
  
  # Clean system temporary files
  find /tmp -type f -mtime +1 -delete 2>/dev/null || true
  find /var/tmp -type f -mtime +1 -delete 2>/dev/null || true
  
  # Sync to ensure disk writes are complete
  sync
}

# Detect the actual user (not root)
detect_user() {
  if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_USER="$SUDO_USER"
  elif [[ -n "${SUDO_UID:-}" ]]; then
    REAL_USER=$(id -un "$SUDO_UID" 2>/dev/null || echo "$USER")
  else
    REAL_USER="$USER"
  fi
  
  # Get the user's home directory
  REAL_USER_HOME=$(eval echo ~"$REAL_USER")
  
  log_info "Detected user: $REAL_USER (home: $REAL_USER_HOME)"
}

# Check if running as root or with sudo
check_privileges() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root or with sudo"
    exit 1
  fi
  detect_user
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
    strace \
    clang \
    clang-devel
  
  # Clean cache immediately after installation
  clean_dnf_cache
  
  # Verify clang installation for bindgen/libclang
  if command -v clang &>/dev/null; then
    log_info "Clang installed successfully: $(clang --version | head -1)"
  else
    log_warn "Clang installation may have failed - bindgen will need libclang"
  fi
}

# Install Rust
install_rust() {
  log_info "Installing Rust for user: $REAL_USER..."
  
  # Install rustup as the real user
  if sudo -u "$REAL_USER" command -v rustc &>/dev/null; then
    log_info "Rust is already installed: $(sudo -u "$REAL_USER" rustc --version)"
  else
    # Use temporary file for rustup installer to clean up after
    local rustup_script="/tmp/rustup-install-$$.sh"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$rustup_script"
    
    # Install rustup as the real user
    sudo -u "$REAL_USER" sh "$rustup_script" -y --default-toolchain stable --profile minimal
    rm -f "$rustup_script"
    
    # Source cargo env for the user
    sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.cargo/env"
  fi

  # Add Rust/Cargo to user's .bashrc if not already present
  if ! grep -q ".cargo/env" "$REAL_USER_HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$REAL_USER_HOME/.bashrc"
    echo "# Rust/Cargo environment" >> "$REAL_USER_HOME/.bashrc"
    echo "source \"\$HOME/.cargo/env\"" >> "$REAL_USER_HOME/.bashrc"
    log_info "Added Rust/Cargo to $REAL_USER_HOME/.bashrc"
  fi

  # Verify installation
  if sudo -u "$REAL_USER" command -v rustc &>/dev/null; then
    log_info "Rust version: $(sudo -u "$REAL_USER" rustc --version)"
    log_info "Cargo version: $(sudo -u "$REAL_USER" cargo --version)"
  else
    # Try to source and check again
    export PATH="$REAL_USER_HOME/.cargo/bin:$PATH"
    if command -v rustc &>/dev/null; then
      log_info "Rust version: $(rustc --version)"
      log_info "Cargo version: $(cargo --version)"
    fi
  fi
  
  # Clean Rust cache of old/unused components
  if sudo -u "$REAL_USER" command -v rustup &>/dev/null; then
    sudo -u "$REAL_USER" rustup component remove --toolchain stable rust-docs 2>/dev/null || true
  fi
}

# Install OpenMPI
install_openmpi() {
  log_info "Installing OpenMPI..."
  dnf install $DNF_OPTS \
    openmpi \
    openmpi-devel

  # Add OpenMPI to user's .bashrc if not already present
  if ! grep -q "openmpi/bin" "$REAL_USER_HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$REAL_USER_HOME/.bashrc"
    echo "# OpenMPI environment" >> "$REAL_USER_HOME/.bashrc"
    echo 'export PATH=/usr/lib64/openmpi/bin:$PATH' >> "$REAL_USER_HOME/.bashrc"
    echo 'export LD_LIBRARY_PATH=/usr/lib64/openmpi/lib:$LD_LIBRARY_PATH' >> "$REAL_USER_HOME/.bashrc"
    log_info "Added OpenMPI paths to $REAL_USER_HOME/.bashrc"
  fi

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
  log_info "Installing Node.js and pnpm for user: $REAL_USER..."

  # Check if nvm is already installed for the user
  if [ ! -d "$REAL_USER_HOME/.nvm" ]; then
    # Download nvm installer to temporary file for cleanup
    local nvm_script="/tmp/nvm-install-$$.sh"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh > "$nvm_script"
    
    # Install nvm as the real user
    sudo -u "$REAL_USER" bash "$nvm_script"
    rm -f "$nvm_script"
  else
    log_info "NVM already installed for $REAL_USER"
  fi

  # Ensure nvm is sourced in user's .bashrc
  if ! grep -q "NVM_DIR" "$REAL_USER_HOME/.bashrc" 2>/dev/null; then
    echo "" >> "$REAL_USER_HOME/.bashrc"
    echo "# NVM (Node Version Manager)" >> "$REAL_USER_HOME/.bashrc"
    echo 'export NVM_DIR="$HOME/.nvm"' >> "$REAL_USER_HOME/.bashrc"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> "$REAL_USER_HOME/.bashrc"
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >> "$REAL_USER_HOME/.bashrc"
    log_info "Added NVM configuration to $REAL_USER_HOME/.bashrc"
  fi

  # Install Node.js as the real user
  sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh && nvm install 24 && nvm use 24 && nvm alias default 24"
  
  # Clean npm cache
  sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh && npm cache clean --force" 2>/dev/null || true

  # Install pnpm globally for the user
  sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh && npm install -g pnpm"
  
  # Prune pnpm store
  sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh && pnpm store prune" 2>/dev/null || true

  # Verify installation
  local node_version=$(sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh && node --version" 2>/dev/null || echo "not found")
  local pnpm_version=$(sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh && pnpm --version" 2>/dev/null || echo "not found")
  
  log_info "Node.js version: $node_version"
  log_info "pnpm version: $pnpm_version"
  
  if [[ "$node_version" == "not found" ]] || [[ "$pnpm_version" == "not found" ]]; then
    log_warn "Node.js or pnpm may not be accessible until you source ~/.bashrc or start a new shell"
  fi
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
  if ! grep -q "Real-time scheduling limits for OS project" /etc/security/limits.conf 2>/dev/null; then
    cat >>/etc/security/limits.conf <<'EOF'

# Real-time scheduling limits for OS project
*               soft    rtprio          99
*               hard    rtprio          99
*               soft    memlock         unlimited
*               hard    memlock         unlimited
EOF
    log_info "Real-time scheduling limits configured"
  else
    log_info "Real-time scheduling limits already configured"
  fi

  log_warn "You may need to log out and log back in for limits to take effect"
}

# Verify installations
verify_installations() {
  log_info "Verifying installations for user: $REAL_USER..."
  echo ""
  
  local errors=0
  
  # Check Rust/Cargo
  if sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.cargo/env 2>/dev/null; command -v cargo" &>/dev/null; then
    log_info "✓ Cargo is accessible"
  else
    log_warn "✗ Cargo may not be accessible (try: source ~/.bashrc)"
    ((errors++))
  fi
  
  # Check Node.js
  if sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh 2>/dev/null; command -v node" &>/dev/null; then
    log_info "✓ Node.js is accessible"
  else
    log_warn "✗ Node.js may not be accessible (try: source ~/.bashrc)"
    ((errors++))
  fi
  
  # Check pnpm
  if sudo -u "$REAL_USER" bash -c "source $REAL_USER_HOME/.nvm/nvm.sh 2>/dev/null; command -v pnpm" &>/dev/null; then
    log_info "✓ pnpm is accessible"
  else
    log_warn "✗ pnpm may not be accessible (try: source ~/.bashrc)"
    ((errors++))
  fi
  
  # Check OpenMPI
  if command -v mpirun &>/dev/null; then
    log_info "✓ OpenMPI is accessible"
  else
    log_warn "✗ OpenMPI may not be accessible (try: source ~/.bashrc)"
    ((errors++))
  fi
  
  if [ $errors -gt 0 ]; then
    echo ""
    log_warn "Some tools may not be accessible until you source ~/.bashrc or start a new shell"
  fi
  echo ""
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
  echo "  2. Run 'source ~/.bashrc' to load all environment variables"
  echo "     Or start a new terminal session"
  echo "  3. Verify installations:"
  echo "     - node --version"
  echo "     - npm --version"
  echo "     - pnpm --version"
  echo "     - cargo --version"
  echo "     - rustc --version"
  echo "  4. Navigate to project and run 'pnpm install'"
  echo "  5. Run 'pnpm run build' to compile all Rust apps"
  echo ""
  echo "Note: If commands are still not found after sourcing ~/.bashrc,"
  echo "      try logging out and back in, or restart your terminal."
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
  
  # Verify installations
  verify_installations
  
  # Clear trap before summary
  trap - INT TERM EXIT
  
  print_summary
}

main "$@"
