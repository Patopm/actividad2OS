#!/bin/bash
#
# Cluster Run Script
#
# Executes prime calculation on the MPI cluster or using TCP fallback.
#
# Usage:
#   ./cluster-run.sh                    # Run with MPI (Docker cluster)
#   ./cluster-run.sh tcp                # Run with TCP (local processes)
#   ./cluster-run.sh benchmark          # Run benchmarks
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_ROOT/results"
DOCKER_DIR="$PROJECT_ROOT/docker"
BINARY="$PROJECT_ROOT/target/release/primes-mpi"

# Configuration
LIMIT=10000000
MPI_PROCESSES=3
TCP_WORKERS=2
TCP_PORT=7878

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$RESULTS_DIR"

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_section() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# Check if cluster is running
check_cluster() {
  if docker ps | grep -q mpi-master; then
    return 0
  else
    return 1
  fi
}

# Run with MPI on Docker cluster
run_mpi_cluster() {
  log_section "RUNNING MPI ON DOCKER CLUSTER"

  if ! check_cluster; then
    log_warn "Cluster is not running. Starting cluster..."
    "$SCRIPT_DIR/cluster-setup.sh" start
    sleep 3
  fi

  log_info "Executing MPI job with $MPI_PROCESSES processes..."
  log_info "Limit: $LIMIT"
  echo ""

  # Run MPI job
  docker exec mpi-master mpirun \
    -np "$MPI_PROCESSES" \
    --hostfile /app/hostfile \
    --allow-run-as-root \
    /app/primes-mpi --limit "$LIMIT" --verbose
}

# Run with TCP (local processes)
run_tcp_local() {
  log_section "RUNNING WITH TCP (LOCAL PROCESSES)"

  # Build if needed
  if [[ ! -f "$BINARY" ]]; then
    log_info "Building binary..."
    cargo build --release -p primes-mpi
  fi

  log_info "Starting TCP-based distributed calculation..."
  log_info "Workers: $TCP_WORKERS"
  log_info "Limit: $LIMIT"
  echo ""

  # Start workers in background
  local pids=()

  for i in $(seq 1 $TCP_WORKERS); do
    log_info "Starting worker $i..."
    "$BINARY" --worker --master-addr "127.0.0.1:$TCP_PORT" --verbose &
    pids+=($!)
    sleep 0.5 # Give worker time to connect
  done

  # Start master
  log_info "Starting master..."
  "$BINARY" --tcp --master-addr "127.0.0.1:$TCP_PORT" --workers "$TCP_WORKERS" --limit "$LIMIT" --verbose

  # Wait for workers to finish
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

# Run benchmarks comparing different configurations
run_benchmarks() {
  log_section "DISTRIBUTED BENCHMARK"

  local output_file="$RESULTS_DIR/benchmark-mpi.csv"
  echo "mode,nodes,limit,time_ms,primes" >"$output_file"

  # Test configurations
  local limits=(1000000 5000000 10000000)
  local iterations=3

  # Single node baseline
  log_info "Running single-node baseline..."
  for limit in "${limits[@]}"; do
    for _ in $(seq 1 $iterations); do
      result=$("$BINARY" --limit "$limit" --csv 2>/dev/null)
      echo "single,1,$limit,$(echo "$result" | cut -d',' -f3),$(echo "$result" | cut -d',' -f4)" >>"$output_file"
    done
  done

  # TCP distributed (2 workers)
  log_info "Running TCP distributed (3 nodes)..."
  for limit in "${limits[@]}"; do
    for i in $(seq 1 $iterations); do
      log_debug "  Iteration $i for limit $limit..."

      "$BINARY" --worker --master-addr "127.0.0.1:$TCP_PORT" >/dev/null 2>&1 &
      w1_pid=$!
      "$BINARY" --worker --master-addr "127.0.0.1:$TCP_PORT" >/dev/null 2>&1 &
      w2_pid=$!

      result=$("$BINARY" --tcp --master-addr "127.0.0.1:$TCP_PORT" --workers 2 --limit "$limit" --csv 2>/dev/null)

      IFS=',' read -r res_limit res_nodes res_time res_count <<<"$result"

      echo "tcp,3,$limit,$res_time,$res_count" >>"$output_file"

      # 4. Clean up: Ensure workers are dead before next iteration
      kill $w1_pid $w2_pid 2>/dev/null || true
      wait $w1_pid $w2_pid 2>/dev/null
    done
  done
  # MPI cluster (if running)
  if check_cluster; then
    log_info "Running MPI cluster (3 nodes)..."
    for limit in "${limits[@]}"; do
      for _ in $(seq 1 $iterations); do
        result=$(docker exec mpi-master mpirun \
          -np 3 \
          --hostfile /app/hostfile \
          --allow-run-as-root \
          /app/primes-mpi --limit "$limit" --csv 2>/dev/null)
        echo "mpi,3,$limit,$(echo "$result" | cut -d',' -f3),$(echo "$result" | cut -d',' -f4)" >>"$output_file"
      done
    done
  else
    log_warn "MPI cluster not running, skipping MPI benchmarks"
  fi

  log_info "Benchmark results saved to: $output_file"
  echo ""

  # Display summary
  log_section "BENCHMARK SUMMARY"
  echo ""
  printf "%-8s %6s %12s %12s %12s\n" "Mode" "Nodes" "Limit" "Time(ms)" "Primes"
  echo "─────────────────────────────────────────────────────────"

  # Calculate averages
  for mode in single tcp mpi; do
    for limit in "${limits[@]}"; do
      avg=$(grep "^$mode," "$output_file" | grep ",$limit," |
        awk -F',' '{sum+=$4; count++} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
      primes=$(grep "^$mode," "$output_file" | grep ",$limit," | head -1 | cut -d',' -f5)
      nodes=$(grep "^$mode," "$output_file" | grep ",$limit," | head -1 | cut -d',' -f2)

      if [[ -n "$avg" && "$avg" != "N/A" ]]; then
        printf "%-8s %6s %12s %12s %12s\n" "$mode" "$nodes" "$limit" "$avg" "$primes"
      fi
    done
  done
}

# Generate comparison report
generate_report() {
  log_section "GENERATING COMPARISON REPORT"

  local report_file="$RESULTS_DIR/cluster-comparison-report.md"

  cat >"$report_file" <<EOF
# Distributed Computing Comparison Report

## Test Configuration

| Parameter | Value |
|-----------|-------|
| Date | $(date) |
| Host | $(hostname) |
| CPU | $(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | xargs || echo "N/A") |

## Benchmark Results

EOF

  if [[ -f "$RESULTS_DIR/benchmark-mpi.csv" ]]; then
    echo '```' >>"$report_file"
    column -t -s',' "$RESULTS_DIR/benchmark-mpi.csv" >>"$report_file"
    echo '```' >>"$report_file"
  fi

  cat >>"$report_file" <<'EOF'

## Analysis

### Single Node vs Distributed

- **Single Node**: Baseline performance with all computation on one machine
- **TCP Distributed**: Network overhead from TCP communication
- **MPI Cluster**: Optimized message passing, better for large workloads

### Scalability Factors

1. **Communication Overhead**: Time spent sending/receiving data
2. **Load Balancing**: How evenly work is distributed
3. **Network Latency**: Impact of network delays
4. **Synchronization**: Time waiting for other nodes

### Recommendations

- For small workloads (< 1M): Single node is often faster
- For medium workloads (1M - 10M): TCP or MPI show benefits
- For large workloads (> 10M): MPI cluster recommended

EOF

  log_info "Report saved to: $report_file"
}

# Main
main() {
  local mode="${1:-mpi}"

  # Build binary if needed
  if [[ ! -f "$BINARY" ]]; then
    log_info "Building primes-mpi..."
    cargo build --release -p primes-mpi
  fi

  case "$mode" in
  mpi | cluster)
    run_mpi_cluster
    ;;
  tcp | local)
    run_tcp_local
    ;;
  benchmark | bench)
    run_benchmarks
    generate_report
    ;;
  single)
    log_section "RUNNING SINGLE NODE"
    "$BINARY" --limit "$LIMIT" --verbose
    ;;
  *)
    echo "Usage: $0 {mpi|tcp|benchmark|single}"
    echo ""
    echo "Modes:"
    echo "  mpi       - Run on Docker MPI cluster"
    echo "  tcp       - Run with TCP (local processes)"
    echo "  benchmark - Run full benchmark comparison"
    echo "  single    - Run on single node"
    exit 1
    ;;
  esac
}

main "$@"
