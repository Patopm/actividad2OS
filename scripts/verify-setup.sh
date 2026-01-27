#!/bin/bash
#
# Verification script for RHEL setup
# Checks if all required tools are accessible and provides fixes
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

log_debug() {
  echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Source bashrc to load all environment variables
source_bashrc() {
  log_info "Sourcing ~/.bashrc to load environment variables..."
  if [ -f "$HOME/.bashrc" ]; then
    source "$HOME/.bashrc" 2>/dev/null || true
    log_info "✓ Sourced ~/.bashrc"
  else
    log_warn "~/.bashrc not found"
  fi
}

# Check if a command exists
check_command() {
  local cmd=$1
  local name=$2
  
  if command -v "$cmd" &>/dev/null; then
    local version=$($cmd --version 2>/dev/null | head -1 || echo "installed")
    log_info "✓ $name: $version"
    return 0
  else
    log_error "✗ $name: command not found"
    return 1
  fi
}

# Check Rust/Cargo
check_rust() {
  echo ""
  log_debug "Checking Rust/Cargo installation..."
  
  # Try sourcing cargo env
  if [ -f "$HOME/.cargo/env" ]; then
    source "$HOME/.cargo/env" 2>/dev/null || true
  fi
  
  check_command "rustc" "Rust"
  check_command "cargo" "Cargo"
  
  if ! command -v cargo &>/dev/null; then
    log_warn "Cargo not found. Try: source ~/.cargo/env"
    log_warn "Or add to ~/.bashrc: source \"\$HOME/.cargo/env\""
  fi
}

# Check Node.js/npm/pnpm
check_node() {
  echo ""
  log_debug "Checking Node.js/npm/pnpm installation..."
  
  # Try sourcing nvm
  if [ -f "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
  fi
  
  check_command "node" "Node.js"
  check_command "npm" "npm"
  check_command "pnpm" "pnpm"
  
  if ! command -v node &>/dev/null; then
    log_warn "Node.js not found. Try: source ~/.nvm/nvm.sh"
    log_warn "Or ensure NVM is configured in ~/.bashrc"
  fi
}

# Check OpenMPI
check_openmpi() {
  echo ""
  log_debug "Checking OpenMPI installation..."
  check_command "mpirun" "OpenMPI"
  
  if ! command -v mpirun &>/dev/null; then
    log_warn "OpenMPI not found. Ensure PATH includes /usr/lib64/openmpi/bin"
  fi
}

# Fix PATH issues
fix_path() {
  echo ""
  log_info "Checking ~/.bashrc configuration..."
  
  local fixes_needed=0
  
  # Check for Rust/Cargo
  if ! grep -q ".cargo/env" "$HOME/.bashrc" 2>/dev/null; then
    log_warn "Rust/Cargo not configured in ~/.bashrc"
    echo "" >> "$HOME/.bashrc"
    echo "# Rust/Cargo environment" >> "$HOME/.bashrc"
    echo "source \"\$HOME/.cargo/env\"" >> "$HOME/.bashrc"
    log_info "✓ Added Rust/Cargo to ~/.bashrc"
    ((fixes_needed++))
  fi
  
  # Check for NVM
  if ! grep -q "NVM_DIR" "$HOME/.bashrc" 2>/dev/null; then
    log_warn "NVM not configured in ~/.bashrc"
    echo "" >> "$HOME/.bashrc"
    echo "# NVM (Node Version Manager)" >> "$HOME/.bashrc"
    echo 'export NVM_DIR="$HOME/.nvm"' >> "$HOME/.bashrc"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> "$HOME/.bashrc"
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >> "$HOME/.bashrc"
    log_info "✓ Added NVM to ~/.bashrc"
    ((fixes_needed++))
  fi
  
  # Check for OpenMPI
  if ! grep -q "openmpi/bin" "$HOME/.bashrc" 2>/dev/null; then
    log_warn "OpenMPI not configured in ~/.bashrc"
    echo "" >> "$HOME/.bashrc"
    echo "# OpenMPI environment" >> "$HOME/.bashrc"
    echo 'export PATH=/usr/lib64/openmpi/bin:$PATH' >> "$HOME/.bashrc"
    echo 'export LD_LIBRARY_PATH=/usr/lib64/openmpi/lib:$LD_LIBRARY_PATH' >> "$HOME/.bashrc"
    log_info "✓ Added OpenMPI to ~/.bashrc"
    ((fixes_needed++))
  fi
  
  if [ $fixes_needed -gt 0 ]; then
    log_info "Applied $fixes_needed fixes to ~/.bashrc"
    log_info "Run 'source ~/.bashrc' or start a new terminal to apply changes"
  else
    log_info "✓ ~/.bashrc is properly configured"
  fi
}

# Main execution
main() {
  echo ""
  echo "=============================================="
  echo "      RHEL SETUP VERIFICATION SCRIPT"
  echo "=============================================="
  echo ""
  
  log_info "Current user: $USER"
  log_info "Home directory: $HOME"
  echo ""
  
  # Source bashrc first
  source_bashrc
  
  # Check all tools
  check_rust
  check_node
  check_openmpi
  
  # Offer to fix PATH issues
  echo ""
  read -p "Do you want to fix PATH issues in ~/.bashrc? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    fix_path
    echo ""
    log_info "Re-sourcing ~/.bashrc..."
    source_bashrc
    echo ""
    log_info "Re-checking tools..."
    check_rust
    check_node
    check_openmpi
  fi
  
  echo ""
  echo "=============================================="
  echo ""
  log_info "Verification complete!"
  echo ""
  log_info "If tools are still not found:"
  echo "  1. Run: source ~/.bashrc"
  echo "  2. Or log out and log back in"
  echo "  3. Or start a new terminal session"
  echo ""
}

main "$@"
