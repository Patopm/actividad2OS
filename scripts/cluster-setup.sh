#!/bin/bash
#
# Cluster Setup Script
#
# Sets up a simulated MPI cluster using Docker containers.
# Creates a 3-node cluster (1 master + 2 workers).
#
# Usage:
#   ./cluster-setup.sh          # Full setup
#   ./cluster-setup.sh build    # Build images only
#   ./cluster-setup.sh start    # Start containers
#   ./cluster-setup.sh stop     # Stop containers
#   ./cluster-setup.sh clean    # Remove everything
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$PROJECT_ROOT/docker"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# Check prerequisites
check_prerequisites() {
  log_section "CHECKING PREREQUISITES"

  # Check Docker
  if ! command -v docker &>/dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
  fi
  log_info "Docker: $(docker --version)"

  # Check Docker Compose
  if docker compose version &>/dev/null; then
    log_info "Docker Compose: $(docker compose version)"
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose &>/dev/null; then
    log_info "Docker Compose: $(docker-compose --version)"
    COMPOSE_CMD="docker-compose"
  else
    log_error "Docker Compose is not installed."
    exit 1
  fi

  # Check if Docker daemon is running
  if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running."
    echo ""
    
    # Try to start Docker service (Linux with systemd)
    if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>/dev/null; then
      log_info "Attempting to start Docker daemon with systemctl..."
      
      # Check if user can run systemctl commands
      if systemctl is-active docker &>/dev/null; then
        log_info "Docker service exists but daemon is not responding"
      fi
      
      # Try to start Docker service
      if sudo systemctl start docker 2>/dev/null; then
        log_info "Docker daemon started successfully"
        # Wait a moment for Docker to be ready
        sleep 3
        if docker info &>/dev/null; then
          log_info "Docker daemon is now running ✓"
        else
          log_error "Docker daemon started but not responding. Please check Docker status manually:"
          echo "  sudo systemctl status docker"
          exit 1
        fi
      else
        log_warn "Could not start Docker daemon automatically (may require password or permissions)."
        echo ""
        log_info "Please start Docker manually:"
        echo "  sudo systemctl start docker"
        echo ""
        log_info "To check Docker status:"
        echo "  sudo systemctl status docker"
        echo ""
        log_info "After starting Docker, run this script again."
        exit 1
      fi
    elif command -v service &>/dev/null; then
      # Try SysV init style
      log_info "Attempting to start Docker daemon with service..."
      if sudo service docker start 2>/dev/null; then
        sleep 3
        if docker info &>/dev/null; then
          log_info "Docker daemon is now running ✓"
        else
          log_error "Docker daemon started but not responding."
          exit 1
        fi
      else
        log_warn "Could not start Docker daemon automatically."
        echo ""
        log_info "Please start Docker manually:"
        echo "  sudo service docker start"
        exit 1
      fi
    else
      # Not a standard Linux init system, provide manual instructions
      echo ""
      log_info "Please start Docker manually:"
      echo "  sudo systemctl start docker    # Linux with systemd"
      echo "  sudo service docker start      # Linux with SysV init"
      echo "  # On macOS/Windows, start Docker Desktop application"
      echo ""
      log_info "After starting Docker, run this script again."
      exit 1
    fi
  else
    log_info "Docker daemon is running ✓"
  fi
}

# Build the Rust binary for the container
build_binary() {
  log_section "BUILDING RUST BINARY"

  cd "$PROJECT_ROOT"

  # Build for release
  log_info "Building primes-mpi..."
  cargo build --release -p primes-mpi

  # Copy binary to docker directory
  log_info "Copying binary to docker directory..."
  cp "$PROJECT_ROOT/target/release/primes-mpi" "$DOCKER_DIR/primes-mpi"

  log_info "Binary built successfully"
}

# Build Docker images
build_images() {
  log_section "BUILDING DOCKER IMAGES"

  cd "$DOCKER_DIR"

  # Create shared directory
  mkdir -p shared

  log_info "Building MPI node image..."
  $COMPOSE_CMD build

  log_info "Docker images built successfully"
}

# Start the cluster
start_cluster() {
  log_section "STARTING CLUSTER"

  cd "$DOCKER_DIR"

  log_info "Starting containers..."
  $COMPOSE_CMD up -d

  # Wait for containers to be ready
  log_info "Waiting for containers to initialize..."
  sleep 5

  # Check container status
  log_info "Container status:"
  $COMPOSE_CMD ps

  # Test SSH connectivity
  log_info "Testing SSH connectivity..."

  for node in mpi-master mpi-worker-1 mpi-worker-2; do
    if docker exec "$node" hostname &>/dev/null; then
      echo "  $node: ✓"
    else
      echo "  $node: ✗"
    fi
  done

  # Copy SSH keys between nodes for passwordless auth
  log_info "Setting up SSH keys between nodes..."

  # Get master's public key
  master_key=$(docker exec mpi-master cat /root/.ssh/id_rsa.pub)

  # Add to all nodes
  for node in mpi-master mpi-worker-1 mpi-worker-2; do
    docker exec "$node" bash -c "echo '$master_key' >> /root/.ssh/authorized_keys"
  done

  # Test MPI connectivity from master
  log_info "Testing MPI connectivity..."
  docker exec mpi-master bash -c "
        source /etc/profile.d/modules.sh 2>/dev/null || true
        for host in mpi-master mpi-worker-1 mpi-worker-2; do
            if ssh -o StrictHostKeyChecking=no -o BatchMode=yes \$host hostname &>/dev/null; then
                echo \"  \$host: ✓\"
            else
                echo \"  \$host: ✗\"
            fi
        done
    "

  log_info "Cluster is ready!"
  echo ""
  echo "To run MPI jobs:"
  echo "  docker exec mpi-master mpirun -np 3 --hostfile /app/hostfile /app/primes-mpi"
  echo ""
  echo "Or use: ./scripts/cluster-run.sh"
}

# Stop the cluster
stop_cluster() {
  log_section "STOPPING CLUSTER"

  cd "$DOCKER_DIR"

  log_info "Stopping containers..."
  $COMPOSE_CMD down

  log_info "Cluster stopped"
}

# Clean up everything
clean_all() {
  log_section "CLEANING UP"

  cd "$DOCKER_DIR"

  log_info "Removing containers and images..."
  $COMPOSE_CMD down --rmi all --volumes 2>/dev/null || true

  log_info "Removing binary..."
  rm -f "$DOCKER_DIR/primes-mpi"

  log_info "Removing shared directory..."
  rm -rf "$DOCKER_DIR/shared"

  log_info "Cleanup complete"
}

# Show cluster status
show_status() {
  log_section "CLUSTER STATUS"

  cd "$DOCKER_DIR"

  echo "Containers:"
  $COMPOSE_CMD ps

  echo ""
  echo "Network:"
  docker network inspect docker_mpi-network 2>/dev/null | grep -A 5 "Containers" ||
    echo "Network not found"
}

# Main
main() {
  local cmd="${1:-setup}"

  case "$cmd" in
  setup | full)
    check_prerequisites
    build_binary
    build_images
    start_cluster
    ;;
  build)
    check_prerequisites
    build_binary
    build_images
    ;;
  start)
    check_prerequisites
    start_cluster
    ;;
  stop)
    stop_cluster
    ;;
  restart)
    stop_cluster
    start_cluster
    ;;
  status)
    show_status
    ;;
  clean)
    stop_cluster
    clean_all
    ;;
  *)
    echo "Usage: $0 {setup|build|start|stop|restart|status|clean}"
    echo ""
    echo "Commands:"
    echo "  setup    - Full setup (build + start)"
    echo "  build    - Build binary and Docker images"
    echo "  start    - Start the cluster"
    echo "  stop     - Stop the cluster"
    echo "  restart  - Restart the cluster"
    echo "  status   - Show cluster status"
    echo "  clean    - Remove everything"
    exit 1
    ;;
  esac
}

main "$@"
